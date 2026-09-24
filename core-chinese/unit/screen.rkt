#lang racket

(require "../atom/width.rkt" rackunit)

;;; unit/screen.rkt —— 后端无关的屏幕帧
;;;
;;; 屏幕有**两条独立通道**：
;;;   1) 文档文本：屏行-片段集（同 外观 的连续文本段） —— 缓冲 文本 + 投影 外观
;;;   2) 视图 覆盖层：光标列表（光标点）+ 选区列表（选中区间） —— 来自 窗口 的选区
;;;
;;; 分开的理由：文档文本是**文档**状态（存 缓冲，随文本移动）；外观 是投影时现算的派生量；
;;; 光标/选区是**视图**状态（存 窗口，临时）。drawing 上后者是叠加层。
;;;
;;; 外观 是**不透明的语义值**（any/c；core 不解释、更不给颜色）——结构由应用自定义。
;;; 提供者 未覆盖的段，core 给 `#f`（纯“无 外观”，不发明任何值）；前端把 外观 映射成样式。
;;; 宽字符不做特殊处理：片段.文本 是原字符，列 是**显示列**（0-based）。

(provide
 (struct-out 片段)
 (struct-out 光标)
 (struct-out 区域)
 (struct-out 窗格)
 屏幕 屏幕? 屏幕-高度 屏幕-宽度 屏幕-光标列表 屏幕-选区列表
 屏幕-空
 屏幕-屏行
 屏幕->屏行列表
 屏幕-屏行->字符串
 屏幕-主选区-光标
 屏幕-光标-屏行
 屏幕-光标-列
 屏幕-损伤
 屏幕-合成
 屏幕->字符串)

(struct 片段 (列 文本 外观) #:transparent)
;; 列  : 显示列（0-based，已按宽字符换算）
;; 文本 : 文本（不含换行）
;; 外观 : any/c  语义值（core 不解释）；结构由应用定义，常用 (hash '外观 '关键字)；未覆盖段 = #f

;; 视图 覆盖层 - 光标点
(struct 光标 (屏行 列 外观 主选区?) #:transparent)
;; 屏行/列  : 显示坐标（0-based）
;; 外观     : any/c  语义值（结构自定），如 (hash '外观 '光标)
;; 主选区? : 是否主光标

;; 视图 覆盖层 - 选中区间（一段连续显示列；一个跨行选区会切成多段）
(struct 区域 (屏行 起点-列 末尾-列 外观) #:transparent)
;; 屏行            : 显示行
;; [起点-列,末尾-列) : 显示列区间（0-based，相对本行）
;; 外观           : any/c  语义值（结构自定），如 (hash '外观 '选区)

(struct 屏幕 (高度 宽度 屏行-片段集 光标列表 选区列表) #:transparent)
;; 高度/宽度 : nat                     帧尺寸（行数 / 列数）
;; 屏行-片段集     : (vectorof (listof 片段)) 文档文本；**不透明**，读用 屏幕-屏行 / 屏幕->屏行列表
;; 光标列表      : (listof 光标)         所有光标（含 主选区）
;; 选区列表   : (listof 区域)         所有选中区间段
;;
;; 主选区 光标 = 光标列表 里 主选区? 为真的那个；其行/列是它的投影（见 屏幕-光标-屏行/列）。

(define (屏幕-空 高度 宽度)
  (屏幕 高度 宽度 (make-vector 高度 '()) '() '()))

;;; ---------- 行读取（直观 API；不暴露内部 vector / struct） ----------
;;; 后端只需：`屏幕->屏行列表` 拿所有行 / `屏幕-屏行` 拿某行；每行是 `(listof 片段)`，
;;; 用 `片段-列` / `片段-文本` / `片段-外观` 读。无需知道内部是 vector。

;; 第 i 行的 片段集：(listof 片段)。越界报错。
(define (屏幕-屏行 s i)
  (unless (and (exact-nonnegative-integer? i) (< i (屏幕-高度 s)))
    (error '屏幕-屏行 "行号越界: ~a（共 ~a 行）" i (屏幕-高度 s)))
  (vector-ref (屏幕-屏行-片段集 s) i))

;; 所有行：(listof (listof 片段))；可直接 `(for ([屏行 (in-list (屏幕->屏行列表 s))]) …)`。
(define (屏幕->屏行列表 s)
  (for/list ([片段集 (in-vector (屏幕-屏行-片段集 s))]) 片段集))

;; 第 i 行的纯文本：片段 间空隙补空格、末尾裁掉。给测试 / 文本后端用。
(define (屏幕-屏行->字符串 s i)
  (define 出 (open-output-string))
  (define 列 0)
  (for ([r (in-list (屏幕-屏行 s i))])
    (when (> (片段-列 r) 列) (display (make-string (- (片段-列 r) 列) #\space) 出))
    (display (片段-文本 r) 出)
    (set! 列 (+ (片段-列 r) (字符串-显示-宽度 (片段-文本 r)))))
  (get-output-string 出))

;; 主选区 光标本身（无 → #f）；行/列是它的投影（无 → -1）。
(define (屏幕-主选区-光标 s)
  (for/first ([c (in-list (屏幕-光标列表 s))] #:when (光标-主选区? c)) c))
(define (屏幕-光标-屏行 s)
  (define c (屏幕-主选区-光标 s)) (if c (光标-屏行 c) -1))
(define (屏幕-光标-列 s)
  (define c (屏幕-主选区-光标 s)) (if c (光标-列 c) -1))

;; 把一帧摊平成纯文本（只含文档文本；不给光标/选区上色）。给测试/无前端驱动用。
(define (屏幕->字符串 s)
  (string-join (for/list ([i (in-range (屏幕-高度 s))]) (屏幕-屏行->字符串 s i)) "\n"))

;; 两帧之间需要**整行重绘**的行号：文本 片段集 变化行 ∪ 覆盖层（光标/选区）变化行。
;; 返回 #f = 必须**整屏重绘**（帧尺寸变了——行数/列数不同，逐行 diff 无意义）。
;; 行号栏开关/宽度变化让**每一行**的 片段 列整体位移 → 自然落入「全部行都损坏」，
;; 所以这里**不认识任何具体 外观**（unit 层不知道 视口 的 外观 约定）。
(define (屏幕-损伤 旧 new)
  (define h (屏幕-高度 new))
  (cond
    [(or (not (= h (屏幕-高度 旧)))
         (not (= (屏幕-宽度 new) (屏幕-宽度 旧)))) #f]
    [else
     ;; 覆盖层 按行分桶一次，逐行只比本行桶（旧实现每行都扫全部光标/选区）。
     (define ov-旧 (覆盖层集-按-屏行 旧 h))
     (define ov-新 (覆盖层集-按-屏行 new h))
     (for/list ([r (in-range h)]
                #:when (or (not (equal? (vector-ref (屏幕-屏行-片段集 旧) r)
                                        (vector-ref (屏幕-屏行-片段集 new) r)))
                           (not (equal? (vector-ref ov-旧 r) (vector-ref ov-新 r)))))
       r)]))

;; 每行的 覆盖层 规范化表示（光标 + 选区，各自按列排序）；返回长度 h 的 vector。
;; 一次遍历光标/选区填桶，用于跨帧逐行比较。
(define (覆盖层集-按-屏行 s h)
  (define 光标列表 (make-vector h '()))
  (define sels (make-vector h '()))
  (for ([c (in-list (屏幕-光标列表 s))])
    (define r (光标-屏行 c))
    (when (and (exact-nonnegative-integer? r) (< r h))
      (vector-set! 光标列表 r
                   (cons (list (光标-列 c) (光标-外观 c) (光标-主选区? c))
                         (vector-ref 光标列表 r)))))
  (for ([g (in-list (屏幕-选区列表 s))])
    (define r (区域-屏行 g))
    (when (and (exact-nonnegative-integer? r) (< r h))
      (vector-set! sels r
                   (cons (list (区域-起点-列 g) (区域-末尾-列 g) (区域-外观 g))
                         (vector-ref sels r)))))
  (for/vector ([r (in-range h)])
    (list (sort (vector-ref 光标列表 r) < #:key car)
          (sort (vector-ref sels r) < #:key car))))

(define (平移-片段 rn x) (片段 (+ x (片段-列 rn)) (片段-文本 rn) (片段-外观 rn)))
(define (平移-光标 c x y) (光标 (+ y (光标-屏行 c)) (+ x (光标-列 c)) (光标-外观 c) (光标-主选区? c)))
(define (平移-区域 rg x y) (区域 (+ y (区域-屏行 rg)) (+ x (区域-起点-列 rg)) (+ x (区域-末尾-列 rg)) (区域-外观 rg)))

;; 一个「贴在合成屏上的子帧」：标识 供 活动 匹配，x/y 是左上角（可负，超出部分裁掉）。
(struct 窗格 (标识 x y 屏幕) #:transparent)

;; 拼屏：把若干 窗格 贴到 (高度 宽度) 大屏。
;; 文本 + 选区按 x/y 平移自各 窗格；**只有 活动 窗格 的光标**被透出（非活动窗格不显示光标）。
(define (屏幕-合成 高度 宽度 窗格集 活动-标识)
  (define 屏行-片段集 (make-vector 高度 '()))
  (define sel-出 '())
  (for ([p (in-list 窗格集)])
    (define x (窗格-x p)) (define y (窗格-y p)) (define s (窗格-屏幕 p))
    (for ([r (in-range (屏幕-高度 s))])
      (define 目标 (+ y r))
      (when (and (>= 目标 0) (< 目标 高度))
        (vector-set! 屏行-片段集 目标 (append (vector-ref 屏行-片段集 目标)
                                          (map (lambda (rn) (平移-片段 rn x))
                                               (vector-ref (屏幕-屏行-片段集 s) r))))))
    (for ([rg (in-list (屏幕-选区列表 s))])
      (set! sel-出 (cons (平移-区域 rg x y) sel-出))))
  (define 已排序 (for/vector ([片段集 (in-vector 屏行-片段集)])
                   (sort 片段集 (lambda (a b) (< (片段-列 a) (片段-列 b))))))
  (define 活动 (for/first ([p (in-list 窗格集)] #:when (equal? (窗格-标识 p) 活动-标识)) p))
  ;; 只透出 活动 窗格 的光标。
  (define 活动-光标列表
    (if 活动
        (map (lambda (c) (平移-光标 c (窗格-x 活动) (窗格-y 活动)))
             (屏幕-光标列表 (窗格-屏幕 活动)))
        '()))
  (屏幕 高度 宽度 已排序 活动-光标列表 sel-出))

;;; ---------- 测试 ----------

(module+ test
  ;; 空帧：尺寸 / 无光标 / 无选区
  (define s0 (屏幕-空 2 10))
  (check-equal? (屏幕-高度 s0) 2)
  (check-equal? (屏幕-光标-屏行 s0) -1)
  (check-equal? (屏幕-光标列表 s0) '())
  (check-equal? (屏幕-选区列表 s0) '())

  ;; 构造 / 屏幕->字符串
  (define r1 (片段 0 "ab" (hash '外观 '粗体)))
  (define r2 (片段 2 "中" (hash '外观 '关键字)))
  (define c1 (光标 0 3 (hash '外观 '光标) #t))
  (define g1 (区域 0 0 2 (hash '外观 '选区)))
  (define s1 (屏幕 2 10 (vector (list r1 r2) '()) (list c1) (list g1)))
  (check-equal? (屏幕->字符串 s1) (string-append "ab中\n"))
  (check-equal? (屏幕-光标-列 s1) 3)
  (check-equal? (光标-主选区? (car (屏幕-光标列表 s1))) #t)
  (check-equal? (区域-末尾-列 (car (屏幕-选区列表 s1))) 2)

  ;; 直观行 API：屏幕-屏行 / 屏幕->屏行列表 / 屏幕-屏行->字符串，越界报错
  (check-equal? (屏幕-屏行 s1 0) (list r1 r2))
  (check-equal? (屏幕->屏行列表 s1) (list (list r1 r2) '()))
  (check-equal? (屏幕-屏行->字符串 s1 0) "ab中")
  (check-equal? (屏幕-屏行->字符串 s1 1) "")
  (check-exn exn:fail? (lambda () (屏幕-屏行 s1 9)))

  ;; 损伤：文本行 ∪ 覆盖层 行；尺寸/行号栏变化 → #f（全屏）
  (define s2 (屏幕 2 10 (vector (list r1 (片段 2 "文" (hash '外观 '关键字))) '()) '() '()))
  (check-equal? (屏幕-损伤 s1 s2) '(0))
  (check-equal? (屏幕-损伤 s1 s1) '())
  (check-equal? (屏幕-损伤 s1 (屏幕 3 10 (vector (list r1 r2) '() '()) '() '())) #f)   ; 尺寸变 → 全屏
  ;; 覆盖层 变化也要报（文本不变、只动光标）
  (define s3 (屏幕 2 10 (vector (list r1 r2) '()) (list (光标 1 1 (hash '外观 '光标) #t)) '()))
  (check-equal? (屏幕-损伤 s1 s3) '(0 1))
  ;; 行号栏变化（片段 变）→ 对应行损坏，不是全屏（unit 层不认识 '行号）
  (define s4 (屏幕 2 10 (vector (list (片段 0 "1 " (hash '外观 '行号)) r1) '()) '() '()))
  (check-equal? (屏幕-损伤 s1 s4) '(0))

  ;; compose：文本/选区平移；只有 活动 块的光标出现
  (define sa (屏幕 2 4 (vector (list (片段 0 "ab" (hash))) (list (片段 0 "cd" (hash))))
                     (list (光标 1 1 (hash '外观 '光标) #t)) (list (区域 0 0 2 (hash '外观 '选区)))))
  (define sb (屏幕 2 4 (vector (list (片段 0 "XY" (hash))) (list (片段 0 "ZW" (hash))))
                     (list (光标 0 0 (hash '外观 '光标) #t)) '()))
  (define comp (屏幕-合成 2 8 (list (窗格 'a 0 0 sa) (窗格 'b 4 0 sb)) 'b))
  (check-equal? (屏幕-屏行 comp 0)
                (list (片段 0 "ab" (hash)) (片段 4 "XY" (hash))))
  (check-equal? (屏幕-屏行 comp 1)
                (list (片段 0 "cd" (hash)) (片段 4 "ZW" (hash))))
  (check-equal? (屏幕-光标-屏行 comp) 0)
  (check-equal? (屏幕-光标-列 comp) 4)
  (check-equal? (map 光标-列 (屏幕-光标列表 comp)) '(4))          ; 只透 活动(b)
  (check-equal? (map 区域-屏行 (屏幕-选区列表 comp)) '(0))       ; 选区来自 a，屏行+0
  (check-equal? (map 区域-起点-列 (屏幕-选区列表 comp)) '(0))
  ;; 活动 不在 窗格集 → 隐藏光标
  (check-equal? (屏幕-光标-屏行 (屏幕-合成 2 8 (list (窗格 'a 0 0 sa)) 'b)) -1)

  (displayln "screen.rkt: all tests passed"))

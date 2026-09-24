#lang racket

(require "../atom/width.rkt" rackunit)

;;; unit/screen.rkt —— 后端无关的屏幕帧
;;;
;;; 屏幕有**两条独立通道**：
;;;   1) 文档文本：row-runs（同 face 的连续文本段） —— buffer 文本 + 投影 face
;;;   2) 视图 overlay：cursors（光标点）+ selections（选中区间） —— 来自 window 的选区
;;;
;;; 分开的理由：文档文本是**文档**状态（存 buffer，随文本移动）；face 是投影时现算的派生量；
;;; 光标/选区是**视图**状态（存 window，临时）。drawing 上后者是叠加层。
;;;
;;; face 是**不透明的语义值**（any/c；core 不解释、更不给颜色）——结构由应用自定义。
;;; provider 未覆盖的段，core 给 `#f`（纯“无 face”，不发明任何值）；前端把 face 映射成样式。
;;; 宽字符不做特殊处理：run.text 是原字符，col 是**显示列**（0-based）。

(provide
 (struct-out run)
 (struct-out cursor)
 (struct-out region)
 (struct-out pane)
 screen screen? screen-height screen-width screen-cursors screen-selections
 screen-empty
 screen-row
 screen->rows
 screen-row->string
 screen-primary-cursor
 screen-cursor-row
 screen-cursor-col
 screen-damage
 screen-compose
 overlay-signatures
 ;; 合成帧（多窗格）：全量 + 增量
 (struct-out composition)
 compose-panes
 compose-panes/incremental
 screen->string)

(struct run (col text face) #:transparent)
;; col  : 显示列（0-based，已按宽字符换算）
;; text : 文本（不含换行）
;; face : any/c  语义值（core 不解释）；结构由应用定义，常用 (hash 'face 'keyword)；未覆盖段 = #f

;; 视图 overlay - 光标点
(struct cursor (row col face primary?) #:transparent)
;; row/col  : 显示坐标（0-based）
;; face     : any/c  语义值（结构自定），如 (hash 'face 'cursor)
;; primary? : 是否主光标

;; 视图 overlay - 选中区间（一段连续显示列；一个跨行选区会切成多段）
(struct region (row start-col end-col face) #:transparent)
;; row            : 显示行
;; [start-col,end-col) : 显示列区间（0-based，相对本行）
;; face           : any/c  语义值（结构自定），如 (hash 'face 'selection)

(struct screen (height width row-runs cursors selections) #:transparent)
;; height/width : nat                     帧尺寸（行数 / 列数）
;; row-runs     : (vectorof (listof run)) 文档文本；**不透明**，读用 screen-row / screen->rows
;; cursors      : (listof cursor)         所有光标（含 primary）
;; selections   : (listof region)         所有选中区间段
;;
;; primary 光标 = cursors 里 primary? 为真的那个；其行/列是它的投影（见 screen-cursor-row/col）。

(define (screen-empty height width)
  (screen height width (make-vector height '()) '() '()))

;;; ---------- 行读取（直观 API；不暴露内部 vector / struct） ----------
;;; 后端只需：`screen->rows` 拿所有行 / `screen-row` 拿某行；每行是 `(listof run)`，
;;; 用 `run-col` / `run-text` / `run-face` 读。无需知道内部是 vector。

;; 第 i 行的 runs：(listof run)。越界报错。
(define (screen-row s i)
  (unless (and (exact-nonnegative-integer? i) (< i (screen-height s)))
    (error 'screen-row "行号越界: ~a（共 ~a 行）" i (screen-height s)))
  (vector-ref (screen-row-runs s) i))

;; 所有行：(listof (listof run))；可直接 `(for ([row (in-list (screen->rows s))]) …)`。
(define (screen->rows s)
  (for/list ([runs (in-vector (screen-row-runs s))]) runs))

;; 第 i 行的纯文本：run 间空隙补空格、末尾裁掉。给测试 / 文本后端用。
(define (screen-row->string s i)
  (define out (open-output-string))
  (define col 0)
  (for ([r (in-list (screen-row s i))])
    (when (> (run-col r) col) (display (make-string (- (run-col r) col) #\space) out))
    (display (run-text r) out)
    (set! col (+ (run-col r) (string-display-width (run-text r)))))
  (get-output-string out))

;; primary 光标本身（无 → #f）；行/列是它的投影（无 → -1）。
(define (screen-primary-cursor s)
  (for/first ([c (in-list (screen-cursors s))] #:when (cursor-primary? c)) c))
(define (screen-cursor-row s)
  (define c (screen-primary-cursor s)) (if c (cursor-row c) -1))
(define (screen-cursor-col s)
  (define c (screen-primary-cursor s)) (if c (cursor-col c) -1))

;; 把一帧摊平成纯文本（只含文档文本；不给光标/选区上色）。给测试/无前端驱动用。
(define (screen->string s)
  (string-join (for/list ([i (in-range (screen-height s))]) (screen-row->string s i)) "\n"))

;; 两帧之间需要**整行重绘**的行号：文本 runs 变化行 ∪ overlay（光标/选区）变化行。
;; 返回 #f = 必须**整屏重绘**（帧尺寸变了——行数/列数不同，逐行 diff 无意义）。
;; 行号栏开关/宽度变化让**每一行**的 run 列整体位移 → 自然落入「全部行都损坏」，
;; 所以这里**不认识任何具体 face**（unit 层不知道 viewport 的 face 约定）。
(define (screen-damage old new)
  (define h (screen-height new))
  (cond
    [(or (not (= h (screen-height old)))
         (not (= (screen-width new) (screen-width old)))) #f]
    [else
     ;; overlay 按行分桶一次，逐行只比本行桶（旧实现每行都扫全部光标/选区）。
     (define ov-old (overlays-by-row old h))
     (define ov-new (overlays-by-row new h))
     (for/list ([r (in-range h)]
                #:when (or (not (equal? (vector-ref (screen-row-runs old) r)
                                        (vector-ref (screen-row-runs new) r)))
                           (not (equal? (vector-ref ov-old r) (vector-ref ov-new r)))))
       r)]))

;; 每行的 overlay 规范化签名（光标 + 选区，各自按列排序）；返回长度 h 的 vector。
;; 用于跨帧逐行比较（screen-damage / 增量投影 / 增量合成）。
(define (overlay-signatures cursors selections h)
  (define cs (make-vector h '()))
  (define gs (make-vector h '()))
  (for ([c (in-list cursors)])
    (define r (cursor-row c))
    (when (and (exact-nonnegative-integer? r) (< r h))
      (vector-set! cs r
                   (cons (list (cursor-col c) (cursor-face c) (cursor-primary? c))
                         (vector-ref cs r)))))
  (for ([g (in-list selections)])
    (define r (region-row g))
    (when (and (exact-nonnegative-integer? r) (< r h))
      (vector-set! gs r
                   (cons (list (region-start-col g) (region-end-col g) (region-face g))
                         (vector-ref gs r)))))
  (for/vector ([r (in-range h)])
    (list (sort (vector-ref cs r) < #:key car)
          (sort (vector-ref gs r) < #:key car))))

(define (overlays-by-row s h)
  (overlay-signatures (screen-cursors s) (screen-selections s) h))

(define (shift-run rn x) (run (+ x (run-col rn)) (run-text rn) (run-face rn)))
(define (shift-cursor c x y) (cursor (+ y (cursor-row c)) (+ x (cursor-col c)) (cursor-face c) (cursor-primary? c)))
(define (shift-region rg x y) (region (+ y (region-row rg)) (+ x (region-start-col rg)) (+ x (region-end-col rg)) (region-face rg)))

;; 一个「贴在合成屏上的子帧」：id 供 active 匹配，x/y 是左上角（可负，超出部分裁掉）。
(struct pane (id x y screen) #:transparent)

;; 拼屏：把若干 pane 贴到 (height width) 大屏。
;; 文本 + 选区按 x/y 平移自各 pane；**只有 active pane 的光标**被透出（非活动窗格不显示光标）。
(define (screen-compose height width panes active-id)
  (define row-runs (for/vector ([row (in-range height)]) (compose-row panes row)))
  (define-values (cursors selections) (compose-overlay panes active-id))
  (screen height width row-runs cursors selections))

;;; ---------- 合成帧（多窗格）：全量 + 增量 ----------

;; 合成帧 = 合成后的屏幕（不透明）+ 参与合成的窗格 + active id。
;; 增量刷新需要旧值（旧窗格布局 / 旧屏幕）才能判断哪些合成行能复用。
(struct composition (height width panes active-id screen) #:transparent)

;; 窗格的几何指纹（id · x · y · 尺寸）：一变就退回全量。
(define (pane-shape p)
  (list (pane-id p) (pane-x p) (pane-y p)
        (screen-height (pane-screen p)) (screen-width (pane-screen p))))

;; 合成一行：把所有覆盖该行的窗格片段右移 x 后按列排序。
(define (compose-row panes row)
  (sort (append*
         (for/list ([p (in-list panes)])
           (define lr (- row (pane-y p)))
           (if (and (>= lr 0) (< lr (screen-height (pane-screen p))))
               (map (lambda (rn) (shift-run rn (pane-x p))) (screen-row (pane-screen p) lr))
               '())))
        < #:key run-col))

;; 合成 overlay：只有 active 窗格的光标 + 所有窗格的选中区。
(define (compose-overlay panes active-id)
  (define active (for/first ([p (in-list panes)] #:when (equal? (pane-id p) active-id)) p))
  (define cursors
    (if active
        (map (lambda (c) (shift-cursor c (pane-x active) (pane-y active)))
             (screen-cursors (pane-screen active)))
        '()))
  (define selections
    (append* (for/list ([p (in-list panes)])
               (map (lambda (g) (shift-region g (pane-x p) (pane-y p)))
                    (screen-selections (pane-screen p))))))
  (values cursors selections))

;; 全量合成：返回 composition（含屏幕）。永远可用——需要整屏重绘时用它。
(define (compose-panes height width panes active-id)
  (composition height width panes active-id (screen-compose height width panes active-id)))

;; 增量合成：dirty-map : pane-id → (or/c #t (listof 局部行号))。
;; 几何（帧尺寸 / 每个窗格 id·x·y·尺寸 / 顺序）没变 → 只重拼脏行 + overlay 变化行；
;; 变了（增删 / 移动 / 缩放 / 改尺寸）→ 退回全量，脏行 = 全部。
(define (compose-panes/incremental old height width panes active-id dirty-map)
  (define same-geometry?
    (and (= (composition-height old) height)
         (= (composition-width old) width)
         (equal? (map pane-shape (composition-panes old)) (map pane-shape panes))))
  (cond
    [(not same-geometry?)
     (values (compose-panes height width panes active-id)
             (for/list ([r (in-range height)]) r))]
    [else
     (define old-screen (composition-screen old))
     (define dirty (make-hash))
     (for ([p (in-list panes)])
       (define d (hash-ref dirty-map (pane-id p) '()))
       (define y (pane-y p))
       (define locals (if (eq? d #t)
                          (for/list ([i (in-range (screen-height (pane-screen p)))]) i)
                          d))
       (for ([lr (in-list locals)])
         (define row (+ y lr))
         (when (and (>= row 0) (< row height)) (hash-set! dirty row #t))))
     (define new-runs
       (for/vector ([row (in-range height)])
         (if (hash-has-key? dirty row)
             (compose-row panes row)
             (screen-row old-screen row))))
     (define-values (cursors selections) (compose-overlay panes active-id))
     (define new-screen (screen height width new-runs cursors selections))
     (define ov-old (overlays-by-row old-screen height))
     (define ov-new (overlays-by-row new-screen height))
     (for ([r (in-range height)] #:when (not (equal? (vector-ref ov-old r) (vector-ref ov-new r))))
       (hash-set! dirty r #t))
     (values (composition height width panes active-id new-screen)
             (sort (for/list ([(k _) (in-hash dirty)]) k) <))]))

;;; ---------- 测试 ----------

(module+ test
  ;; 空帧：尺寸 / 无光标 / 无选区
  (define s0 (screen-empty 2 10))
  (check-equal? (screen-height s0) 2)
  (check-equal? (screen-cursor-row s0) -1)
  (check-equal? (screen-cursors s0) '())
  (check-equal? (screen-selections s0) '())

  ;; 构造 / screen->string
  (define r1 (run 0 "ab" (hash 'face 'bold)))
  (define r2 (run 2 "中" (hash 'face 'keyword)))
  (define c1 (cursor 0 3 (hash 'face 'cursor) #t))
  (define g1 (region 0 0 2 (hash 'face 'selection)))
  (define s1 (screen 2 10 (vector (list r1 r2) '()) (list c1) (list g1)))
  (check-equal? (screen->string s1) (string-append "ab中\n"))
  (check-equal? (screen-cursor-col s1) 3)
  (check-equal? (cursor-primary? (car (screen-cursors s1))) #t)
  (check-equal? (region-end-col (car (screen-selections s1))) 2)

  ;; 直观行 API：screen-row / screen->rows / screen-row->string，越界报错
  (check-equal? (screen-row s1 0) (list r1 r2))
  (check-equal? (screen->rows s1) (list (list r1 r2) '()))
  (check-equal? (screen-row->string s1 0) "ab中")
  (check-equal? (screen-row->string s1 1) "")
  (check-exn exn:fail? (lambda () (screen-row s1 9)))

  ;; damage：文本行 ∪ overlay 行；尺寸/行号栏变化 → #f（全屏）
  (define s2 (screen 2 10 (vector (list r1 (run 2 "文" (hash 'face 'keyword))) '()) '() '()))
  (check-equal? (screen-damage s1 s2) '(0))
  (check-equal? (screen-damage s1 s1) '())
  (check-equal? (screen-damage s1 (screen 3 10 (vector (list r1 r2) '() '()) '() '())) #f)   ; 尺寸变 → 全屏
  ;; overlay 变化也要报（文本不变、只动光标）
  (define s3 (screen 2 10 (vector (list r1 r2) '()) (list (cursor 1 1 (hash 'face 'cursor) #t)) '()))
  (check-equal? (screen-damage s1 s3) '(0 1))
  ;; 行号栏变化（run 变）→ 对应行损坏，不是全屏（unit 层不认识 'line-number）
  (define s4 (screen 2 10 (vector (list (run 0 "1 " (hash 'face 'line-number)) r1) '()) '() '()))
  (check-equal? (screen-damage s1 s4) '(0))

  ;; compose：文本/选区平移；只有 active 块的光标出现
  (define sa (screen 2 4 (vector (list (run 0 "ab" (hash))) (list (run 0 "cd" (hash))))
                     (list (cursor 1 1 (hash 'face 'cursor) #t)) (list (region 0 0 2 (hash 'face 'selection)))))
  (define sb (screen 2 4 (vector (list (run 0 "XY" (hash))) (list (run 0 "ZW" (hash))))
                     (list (cursor 0 0 (hash 'face 'cursor) #t)) '()))
  (define comp (screen-compose 2 8 (list (pane 'a 0 0 sa) (pane 'b 4 0 sb)) 'b))
  (check-equal? (screen-row comp 0)
                (list (run 0 "ab" (hash)) (run 4 "XY" (hash))))
  (check-equal? (screen-row comp 1)
                (list (run 0 "cd" (hash)) (run 4 "ZW" (hash))))
  (check-equal? (screen-cursor-row comp) 0)
  (check-equal? (screen-cursor-col comp) 4)
  (check-equal? (map cursor-col (screen-cursors comp)) '(4))          ; 只透 active(b)
  (check-equal? (map region-row (screen-selections comp)) '(0))       ; 选区来自 a，row+0
  (check-equal? (map region-start-col (screen-selections comp)) '(0))
  ;; active 不在 panes → 隐藏光标
  (check-equal? (screen-cursor-row (screen-compose 2 8 (list (pane 'a 0 0 sa)) 'b)) -1)

  ;; composition 增量：只改窗格 a 的第 0 行 → 合成脏行 = (0)，非脏行原样复用
  (define ca0 (screen 2 4 (vector (list (run 0 "ab" 'f)) (list (run 0 "cd" 'f))) '() '()))
  (define ca1 (screen 2 4 (vector (list (run 0 "aX" 'f)) (list (run 0 "cd" 'f))) '() '()))
  (define cb  (screen 2 4 (vector (list (run 0 "XY" 'f)) (list (run 0 "ZW" 'f))) '() '()))
  (define cp0 (compose-panes 2 8 (list (pane 'a 0 0 ca0) (pane 'b 4 0 cb)) 'a))
  (define-values (cp1 cpd) (compose-panes/incremental cp0 2 8 (list (pane 'a 0 0 ca1) (pane 'b 4 0 cb)) 'a (hash 'a '(0))))
  (check-equal? cpd '(0))
  (check-equal? (screen-row (composition-screen cp1) 0) (list (run 0 "aX" 'f) (run 4 "XY" 'f)))
  (check-equal? (screen-row (composition-screen cp1) 1) (list (run 0 "cd" 'f) (run 4 "ZW" 'f)))

  ;; 几何变（pane b 右移）→ 全量，脏行 = 全部
  (define-values (_cp2 cpd2) (compose-panes/incremental cp0 2 8 (list (pane 'a 0 0 ca1) (pane 'b 5 0 cb)) 'a (hash)))
  (check-equal? cpd2 '(0 1))

  ;; active 变 → overlay 变化行脏（a 的光标没了 / b 的光标出现）
  (define ca-c (screen 2 4 (vector (list (run 0 "ab" 'f)) (list (run 0 "cd" 'f))) (list (cursor 0 1 'c #t)) '()))
  (define cb-c (screen 2 4 (vector (list (run 0 "XY" 'f)) (list (run 0 "ZW" 'f))) (list (cursor 1 0 'c #t)) '()))
  (define cp3 (compose-panes 2 8 (list (pane 'a 0 0 ca-c) (pane 'b 4 0 cb)) 'a))
  (define-values (cp4 cpd4) (compose-panes/incremental cp3 2 8 (list (pane 'a 0 0 ca-c) (pane 'b 4 0 cb-c)) 'b (hash)))
  (check-equal? cpd4 '(0 1))
  (check-equal? (map cursor-row (screen-cursors (composition-screen cp4))) '(1))

  (displayln "screen.rkt: all tests passed"))

#lang racket

(require "../atom/point.rkt" "../doc/buffer.rkt" "../doc/document.rkt" "window.rkt" "render.rkt"
         "../atom/width.rkt" "../unit/screen.rkt" rackunit)

;;; viewport/layout.rkt —— 显示布局：虚拟行（视觉行）
;;;
;;; 虚拟行 = 一条屏幕行对应的文本来源 (缓冲行, 显示列范围)。两种显示方式只影响
;;; 「怎么生成 虚拟行 序列」，之后的渲染、光标/鼠标映射、滚动完全共用：
;;;   裁剪：一条 缓冲 行 = 一条 虚拟行，列范围 = [左列, 左列+宽度)
;;;   折行：一条 缓冲 行 = 若干段，每段宽 ≤ 宽度，宽字符绝不切半
;;;
;;; 列一律是**显示列**（宽度 换算后）；位置 的 列 是字符索引，映射时换算。

(provide
 (struct-out 虚拟行)
 行范围->片段集
 行范围->片段集/字形集
 折行-段列表
 布局-裁剪
 布局-折行
 窗口-虚拟行集
 窗口-边栏-宽度
 窗口-内容-宽度
 窗口-位置->屏幕
 窗口-位置->屏幕/虚拟行集
 窗口-屏幕->位置
 窗口-滚动
 窗口-确保-位置
 窗口-夹紧-视口
 窗口-视觉-移动
 位置-上
 位置-下
 窗口-上
 窗口-下)

(struct 虚拟行 (行 起点-列 末尾-列) #:transparent)
;; 行      : 缓冲 行号（-1 = 空白行）
;; 起点-列 : 起始显示列（0-based）
;; 末尾-列   : 结束显示列（不含）

;;; ---------- 一行 [起点,末尾) 显示列 → 片段集 ----------

(define (行范围->片段集 b li 起点 末尾 [外观-提供者 空外观提供者])
  (行范围->片段集/字形集 (已渲染-行-字形集 (渲染-行 b li 外观-提供者)) 起点 末尾))

;; 同上，但已渲染的 字形集 由调用方传入 —— 同一行在 折行 下会对应多个 虚拟行（多个
;; [起点,末尾) 段），一次渲染、多次切片，不必每个 虚拟行 都整行重渲。
(define (行范围->片段集/字形集 字形集 起点 末尾)
  (define n (vector-length 字形集))
  (define 单元集
    (let loop ([i 0] [列 0] [acc '()])
      (cond
        [(>= i n) (reverse acc)]
        [else
         (define g (vector-ref 字形集 i))
         (define 字符 (字形-字符 g)) (define 外观 (字形-外观 g))
         (define cend (+ 列 (字符-显示-宽度 字符)))
         (cond
           [(< cend 起点) (loop (add1 i) cend acc)]        ; 全在左界之外
           [(>= 列 末尾) (reverse acc)]                     ; 已到右界之外
           ;; 跨任意边界（左右同一规则）：字符未完整落在 [起点,末尾) → 整字丢弃。
           [(or (< 列 起点) (> cend 末尾)) (loop (add1 i) cend acc)]
           [else (loop (add1 i) cend (cons (list (- 列 起点) 字符 外观) acc))])])))
  (单元集->片段集 单元集))

(struct 单元片段 (列 外观 字符集 宽度) #:transparent)

(define (单元片段->片段 r)
  (片段 (单元片段-列 r) (list->string (reverse (单元片段-字符集 r))) (单元片段-外观 r)))

(define (单元集->片段集 单元集)
  (define-values (片段集 cur)
    (for/fold ([片段集 '()] [cur #f]) ([c (in-list 单元集)])
      (match-define (list 列 字符 外观) c)
      (cond
        [(and cur (equal? 外观 (单元片段-外观 cur))
              (= (+ (单元片段-列 cur) (单元片段-宽度 cur)) 列))
         (values 片段集 (struct-copy 单元片段 cur
                        [字符集 (cons 字符 (单元片段-字符集 cur))]
                        [宽度 (+ (单元片段-宽度 cur) (字符-显示-宽度 字符))]))]
        [else
         (values (if cur (cons (单元片段->片段 cur) 片段集) 片段集)
                 (单元片段 列 外观 (list 字符) (字符-显示-宽度 字符)))])))
  (reverse (if cur (cons (单元片段->片段 cur) 片段集) 片段集)))

;;; ---------- 折行边界 ----------
;; 文本 → (listof (cons 起点-列 末尾-列))，每段宽 ≤ 宽度，宽字符绝不切半；空行给一段 [0,0)。

(define (折行-段列表 文本 宽度)
  (define n (string-length 文本))
  (define 段集
    (let loop ([i 0] [列 0] [段-起点 0] [acc '()])
      (cond
        [(>= i n) (reverse (if (> 列 段-起点) (cons (cons 段-起点 列) acc) acc))]
        [else
         (define w (字符-显示-宽度 (string-ref 文本 i)))
         (cond
           [(zero? w) (loop (add1 i) 列 段-起点 acc)]          ; 组合字符附着
           [(and (> 列 段-起点) (> (+ (- 列 段-起点) w) 宽度))
            (loop i 列 列 (cons (cons 段-起点 列) acc))]     ; 放不下 → 换段
           [else (loop (add1 i) (+ 列 w) 段-起点 acc)])])))    ; 空段总接受（单字>宽度也放）
  (cond
    [(null? 段集) (list (cons 0 0))]
    ;; 末段正好填满 宽度：行尾插入点需要单独一个视觉行（否则光标落在窗口右边界之外）
    [(= (- (cdr (last 段集)) (car (last 段集))) 宽度)
     (append 段集 (list (cons (cdr (last 段集)) (cdr (last 段集)))))]
    [else 段集]))

;;; ---------- 布局 ----------

;; 行号栏宽度：当前视口行号上界的位数 + 1 分隔空格；关闭 → 0。
;; 上界用 顶行 + 高度（而非精确可见行）：折行 下“栏宽 → 正文宽 → 折行 → 可见行 → 栏宽”
;; 成环，会抖；顶部+高度 与 模式 无关、单调、无环（最多多留一格）。
(define (窗口-边栏-宽度 w)
  (cond
    [(not (窗口-行号? w)) 0]
    [else
     (define n (缓冲-行-数量 (窗口-缓冲 w)))
     (define 最大-行 (min n (+ (窗口-顶行 w) (窗口-高度 w))))
     (define 数字集 (string-length (number->string 最大-行)))
     (min (+ 数字集 1) (max 0 (sub1 (窗口-宽度 w))))]))   ; 栏不得吃掉全部列

;; 正文可用宽度 = 总宽 - 行号栏宽度（至少 1 列）。布局 内部一律用它，而非 窗口-宽度。
(define (窗口-内容-宽度 w)
  (max 1 (- (窗口-宽度 w) (窗口-边栏-宽度 w))))

(define (布局-裁剪 b 顶行 左列 宽度 高度)
  (for/vector ([屏行 (in-range 高度)])
    (define li (+ 顶行 屏行))
    (if (< li (缓冲-行-数量 b))
        (虚拟行 li 左列 (+ 左列 宽度))
        (虚拟行 -1 0 0))))

(define (布局-折行 b 顶行 顶段 宽度 高度)
  (let loop ([行 顶行]
             [段集 (list->vector (折行-段列表 (缓冲-行-引用 b 顶行) 宽度))]
             [段 顶段] [屏行 0] [acc '()])
    (cond
      [(>= 屏行 高度) (list->vector (reverse acc))]
      [(>= 行 (缓冲-行-数量 b))
       (list->vector (append (reverse acc)
                             (for/list ([r (in-range 屏行 高度)]) (虚拟行 -1 0 0))))]
      [else
       (cond
         [(< 段 (vector-length 段集))
          (define s (vector-ref 段集 段))
          (loop 行 段集 (add1 段) (add1 屏行) (cons (虚拟行 行 (car s) (cdr s)) acc))]
         [else
          (define 下一个 (add1 行))
          (if (>= 下一个 (缓冲-行-数量 b))
              (list->vector (append (reverse acc)
                                    (for/list ([r (in-range 屏行 高度)]) (虚拟行 -1 0 0))))
              (loop 下一个 (list->vector (折行-段列表 (缓冲-行-引用 b 下一个) 宽度))
                    0 屏行 acc))])])))

(define (窗口-虚拟行集 w)
  (define b (窗口-缓冲 w))
  (case (窗口-模式 w)
    ['裁剪 (布局-裁剪 b (窗口-顶行 w) (窗口-左列 w)
                        (窗口-内容-宽度 w) (窗口-高度 w))]
    ['折行 (布局-折行 b (窗口-顶行 w) (窗口-顶段 w)
                        (窗口-内容-宽度 w) (窗口-高度 w))]
    [else (检查模式 '窗口-虚拟行集 (窗口-模式 w))]))

;;; ---------- 视口自洽（夹紧）----------

;; 最大 顶行（缓冲 行号）：从这个行号起能看到**足够填满一屏**的视觉行。
;; 从末尾往回数折行段，只走到「够 高度 段」为止 —— O(高度 × 行长)，与总行数无关；
;; 旧实现的 视觉-行-数量 要折行**整个 缓冲**（O(全文)），在文件末尾编辑时每键都付这个代价。
(define (最大顶行 b 宽度 高度 模式)
  (case 模式
    ['裁剪 (max 0 (- (缓冲-行-数量 b) 高度))]
    ['折行
     (let loop ([行 (sub1 (缓冲-行-数量 b))] [段集 0])
       (cond
         [(< 行 0) 0]
         [else
          (define s (length (折行-段列表 (缓冲-行-引用 b 行) 宽度)))
          (if (>= (+ 段集 s) 高度) 行 (loop (sub1 行) (+ 段集 s)))]))]
    [else (检查模式 '最大顶行 模式)]))

;; 把视口夹回合法域：顶部/顶段 在范围内、左列 吸附到字符起点。
;; 自由 视图「视口钉住」= 钉住**但仍在合法域内**；否则别的视图删短内容后
;; 裁剪 会静默全空白、折行 会抛 vector-ref。
(define (窗口-夹紧-视口 w)
  (define b (窗口-缓冲 w))
  (define n (缓冲-行-数量 b))
  ;; 顶行 是 **缓冲 行号**（不是视觉行号）；若不夹到 最大顶行 / (sub1 n)，
  ;; 折行 下会滚出末页、布局-折行 的 缓冲-行-引用 会崩。
  (define 顶部
    (max 0 (min (窗口-顶行 w)
                (最大顶行 b (窗口-内容-宽度 w) (窗口-高度 w) (窗口-模式 w))
                (sub1 n))))
  (define tline 顶部)
  (define ttext (缓冲-行-引用 b tline))
  (define 最大-段 (case (窗口-模式 w)
                    ['裁剪 0]
                    ['折行 (max 0 (sub1 (length (折行-段列表 ttext (窗口-内容-宽度 w)))))]
                    [else (检查模式 '窗口-夹紧-视口 (窗口-模式 w))]))
  (struct-copy 窗口 w
    [顶行 顶部]
    [顶段 (max 0 (min (窗口-顶段 w) 最大-段))]
    [左列 (吸附-左列 ttext (窗口-左列 w))]))

;;; ---------- 光标 / 鼠标映射 ----------

;; 虚拟行 是否是它那条 缓冲 行在当前窗口里的最后一段（行尾归属）
(define (虚拟行-行的末段? 虚拟行集 屏行)
  (or (= 屏行 (sub1 (vector-length 虚拟行集)))
      (not (= (虚拟行-行 (vector-ref 虚拟行集 屏行))
              (虚拟行-行 (vector-ref 虚拟行集 (add1 屏行)))))))

;; 位置 → 屏幕 (屏行 列)；不给 p 就用 窗口 的 主选区 光标；不可见 → (values #f #f)
(define (窗口-位置->屏幕 w [p (窗口-位置 w)])
  (窗口-位置->屏幕/虚拟行集 w (窗口-虚拟行集 w) p))

;; 同上，但视口 虚拟行集 由调用方传入（多光标投影时避免每个光标重建整屏 虚拟行集）。
(define (窗口-位置->屏幕/虚拟行集 w 虚拟行集 p)
  (define b (窗口-缓冲 w))
  (define 行 (位置-行 p))
  (define 目标项 (索引->显示列 (缓冲-行-引用 b 行) (位置-列 p)))
  (let loop ([屏行 0])
    (cond
      [(>= 屏行 (vector-length 虚拟行集)) (values #f #f)]
      [else
       (define vr (vector-ref 虚拟行集 屏行))
       (define 命中? (and (= (虚拟行-行 vr) 行)
                         (or (and (<= (虚拟行-起点-列 vr) 目标项) (< 目标项 (虚拟行-末尾-列 vr)))
                             (and (= 目标项 (虚拟行-末尾-列 vr))
                                  ;; 行尾插入点：只有落在正文宽度内才算可见（否则宁可不画）
                                  (< (- 目标项 (虚拟行-起点-列 vr)) (窗口-内容-宽度 w))
                                  (虚拟行-行的末段? 虚拟行集 屏行)))))
       (if 命中? (values 屏行 (- 目标项 (虚拟行-起点-列 vr))) (loop (add1 屏行)))])))

;; 屏幕 (屏行 列) → 缓冲 (行 列)；越界 → (values #f #f)
(define (窗口-屏幕->位置 w 屏行 列)
  (define g (窗口-边栏-宽度 w))                       ; 行号栏列 → 视作正文列 0
  (define 虚拟行集 (窗口-虚拟行集 w))
  (cond
    [(or (< 屏行 0) (>= 屏行 (vector-length 虚拟行集))) (values #f #f)]
    [else
     (define vr (vector-ref 虚拟行集 屏行))
     (if (< (虚拟行-行 vr) 0)
         (values #f #f)
         (values (虚拟行-行 vr)
                 (显示列->索引 (缓冲-行-引用 (窗口-缓冲 w) (虚拟行-行 vr))
                                (+ (虚拟行-起点-列 vr) (max 0 (- 列 g))))))]))

;;; ---------- 视觉行滚动 ----------

(define (窗口-滚动 w 增量)
  (case (窗口-模式 w)
    ['裁剪 (窗口-垂直滚动 w 增量)]
    ['折行 (窗口-滚动-折行 w 增量)]
    [else (检查模式 '窗口-滚动 (窗口-模式 w))]))

(define (窗口-滚动-折行 w 增量)
  (define b (窗口-缓冲 w))
  (define 宽度 (窗口-内容-宽度 w))
  (define (nseg 行) (length (折行-段列表 (缓冲-行-引用 b 行) 宽度)))
  (cond
    [(> 增量 0)
     (let loop ([行 (窗口-顶行 w)] [段 (窗口-顶段 w)] [k 增量])
       (cond
         [(or (<= k 0) (>= 行 (缓冲-行-数量 b)))
          (struct-copy 窗口 w [顶行 行] [顶段 段])]
         [else
          (define s (nseg 行))
          (if (< (add1 段) s) (loop 行 (add1 段) (sub1 k))
              (loop (add1 行) 0 (sub1 k)))]))]
    [(< 增量 0)
     (let loop ([行 (窗口-顶行 w)] [段 (窗口-顶段 w)] [k (- 增量)])
       (cond
         [(<= k 0) (struct-copy 窗口 w [顶行 行] [顶段 段])]
         [else
          (cond
            [(> 段 0) (loop 行 (sub1 段) (sub1 k))]
            [(> 行 0) (loop (sub1 行) (max 0 (sub1 (nseg (sub1 行)))) (sub1 k))]
            [else (struct-copy 窗口 w [顶行 0] [顶段 0])])]))]
    [else w]))

;;; ---------- 光标跟随滚动 ----------

;; 目标显示列落在第几个折行段（不在任何段内 → 末段）；返回 (values 段号 段起始列)。
;; 一次遍历（不能用 (list-ref 段集 i) —— 那会退化成 O(段数²)）。
(define (段-在 段集 目标项-列)
  (let loop ([i 0] [rest 段集])
    (cond
      [(null? (cdr rest)) (values i (car (car rest)))]
      [else
       (define s (car rest))
       (if (and (<= (car s) 目标项-列) (< 目标项-列 (cdr s)))
           (values i (car s))
           (loop (add1 i) (cdr rest)))])))

(define (视觉-距离 b 从-行 从-段 到-行 到-段 宽度)
  (cond
    [(> 从-行 到-行) 0]
    [(= 从-行 到-行) (- 到-段 从-段)]
    [else
     (+ (- (length (折行-段列表 (缓冲-行-引用 b 从-行) 宽度)) 从-段)
        (for/sum ([l (in-range (add1 从-行) 到-行)])
          (length (折行-段列表 (缓冲-行-引用 b l) 宽度)))
        到-段)]))

(define (确保-裁剪 w 行 目标项-列)
  (define b (窗口-缓冲 w))
  (define 高度 (窗口-高度 w)) (define 宽度 (窗口-内容-宽度 w))
  (define 文本 (缓冲-行-引用 b 行))
  ;; 行尾插入点也**占一格**：否则 目标项 = 左+宽度 时右滚条件不成立，
  ;; 光标会停到窗口右边界之外（位置->屏幕 返回 列 = 宽度）。
  (define cw (let ([ci (显示列->索引 文本 目标项-列)])
               (if (= ci (string-length 文本)) 1
                   (字符-显示-宽度 (string-ref 文本 ci)))))
  (define 顶部 (cond [(< 行 (窗口-顶行 w)) 行]
                    [(>= 行 (+ (窗口-顶行 w) 高度)) (+ (- 行 高度) 1)]
                    [else (窗口-顶行 w)]))
  (define 最大-顶部 (max 0 (- (缓冲-行-数量 b) 高度)))
  (define 左
    (cond
      [(< 目标项-列 (窗口-左列 w)) 目标项-列]
      [(> (+ 目标项-列 cw) (+ (窗口-左列 w) 宽度))
       (吸附-显示列-前向 文本 (max 0 (min 目标项-列 (- (+ 目标项-列 cw) 宽度))))]
      [else (窗口-左列 w)]))
  (struct-copy 窗口 w [顶行 (min (max 0 顶部) 最大-顶部)] [左列 左]))

(define (确保-折行 w 行 目标项-列)
  (define b (窗口-缓冲 w))
  (define 宽度 (窗口-内容-宽度 w)) (define 高度 (窗口-高度 w))
  (define 段集 (折行-段列表 (缓冲-行-引用 b 行) 宽度))
  (define-values (段 _) (段-在 段集 目标项-列))
  (define 顶行 (窗口-顶行 w)) (define 顶段 (窗口-顶段 w))
  (cond
    [(< 行 顶行) (struct-copy 窗口 w [顶行 行] [顶段 0])]
    [(and (= 行 顶行) (< 段 顶段)) (struct-copy 窗口 w [顶段 段])]
    [else
     (define 距离 (视觉-距离 b 顶行 顶段 行 段 宽度))
     (if (< 距离 高度) w (窗口-滚动 w (+ (- 距离 高度) 1)))]))

(define (窗口-确保-位置 w)
  (define b (窗口-缓冲 w))
  (define p (窗口-位置 w))
  (define 行 (位置-行 p))
  (define 目标项 (索引->显示列 (缓冲-行-引用 b 行) (位置-列 p)))
  (case (窗口-模式 w)
    ['裁剪 (确保-裁剪 w 行 目标项)]
    ['折行 (确保-折行 w 行 目标项)]
    [else (检查模式 '窗口-确保-位置 (窗口-模式 w))]))

;;; ---------- 视觉行移动 ----------
;; 上下键按**视觉行**移动：裁剪 按 缓冲 行、折行 按折行段，统一保持「视觉列」。

(define (行-段列表 b 行 宽度 模式)
  (define 文本 (缓冲-行-引用 b 行))
  (case 模式
    ['裁剪 (list (cons 0 (字符串-显示-宽度 文本)))]
    ['折行 (折行-段列表 文本 宽度)]
    [else (检查模式 '行-段列表 模式)]))

(define (视觉-移动 b 行 列 宽度 模式 增量)
  (define n (缓冲-行-数量 b))
  (define 文本 (缓冲-行-引用 b 行))
  (define dc (索引->显示列 文本 列))
  (define 段集 (行-段列表 b 行 宽度 模式))
  (define-values (si 段-起点) (段-在 段集 dc))
  (define vc (- dc 段-起点))
  (define 目标项
    (cond
      [(< 增量 0)
       (cond [(> si 0) (match-define (cons s e) (list-ref 段集 (sub1 si))) (虚拟行 行 s e)]
             [(> 行 0) (match-define (cons s e) (last (行-段列表 b (sub1 行) 宽度 模式)))
                         (虚拟行 (sub1 行) s e)]
             [else #f])]
      [(> 增量 0)
       (cond [(< si (sub1 (length 段集))) (match-define (cons s e) (list-ref 段集 (add1 si))) (虚拟行 行 s e)]
             [(< 行 (sub1 n)) (match-define (cons s e) (car (行-段列表 b (add1 行) 宽度 模式)))
                                (虚拟行 (add1 行) s e)]
             [else #f])]
      [else #f]))
  (cond
    [(not 目标项) (values #f #f)]
    [else
     (define tl (虚拟行-行 目标项)) (define ts (虚拟行-起点-列 目标项)) (define te (虚拟行-末尾-列 目标项))
     (define tw (- te ts))
     (define ttext (缓冲-行-引用 b tl))
     (define 行-宽度 (字符串-显示-宽度 ttext))
     (define tdc (吸附-显示列-前向 ttext (+ ts (min vc tw))))
     ;; tdc == te 有两个来源：夹到段尾，或段尾宽字符右半格被吸附。都取段内最后一个字符。
     (define tcol (if (and (= tdc te) (< te 行-宽度))
                      (显示列->索引 ttext (sub1 te))
                      (显示列->索引 ttext tdc)))
     (values tl tcol)]))

(define (窗口-位置-视觉-移动 w p 增量)
  (define b (窗口-缓冲 w))
  (define-values (l c) (视觉-移动 b (位置-行 p) (位置-列 p)
                                    (窗口-内容-宽度 w) (窗口-模式 w) 增量))
  (if l (位置 l c) p))

(define (位置-上 w p)   (窗口-位置-视觉-移动 w p -1))
(define (位置-下 w p) (窗口-位置-视觉-移动 w p +1))

(define (窗口-视觉-移动 w 增量)
  (窗口-映射-位置列表 w (lambda (p) (窗口-位置-视觉-移动 w p 增量))))

(define (窗口-上 w)   (窗口-视觉-移动 w -1))
(define (窗口-下 w) (窗口-视觉-移动 w +1))

;;; ---------- 测试 ----------

(module+ test
  ;; 行范围->片段集：宽字符 + 裁剪
  (define b0 (缓冲-打开 "a中b\nc"))
  (check-equal? (行范围->片段集 b0 0 0 10) (list (片段 0 "a中b" #f)))
  (check-equal? (行范围->片段集 b0 0 2 10) (list (片段 1 "b" #f)))   ; 左界切丢「中」

  ;; 折行-段列表
  (check-equal? (折行-段列表 "aaaa中中中" 5) '((0 . 4) (4 . 8) (8 . 10)))
  (check-equal? (折行-段列表 "中" 1) '((0 . 2)))
  (check-equal? (折行-段列表 "" 5) '((0 . 0)))

  ;; 裁剪 布局
  (define b1 (文档-打开 "l1\nl2\nl3"))
  (define wc (窗口-打开 b1 2 80))
  (check-equal? (map (lambda (v) (list (虚拟行-行 v) (虚拟行-起点-列 v)))
                     (vector->list (窗口-虚拟行集 wc)))
                '((0 0) (1 0)))

  ;; 折行 布局
  (define ww (窗口-设置-模式 (窗口-打开 (文档-打开 "中中中\nx") 3 4) '折行))
  (check-equal? (map (lambda (v) (list (虚拟行-行 v) (虚拟行-起点-列 v) (虚拟行-末尾-列 v)))
                     (vector->list (窗口-虚拟行集 ww)))
                '((0 0 4) (0 4 6) (1 0 1)))

  ;; 光标映射
  (check-equal? (call-with-values (lambda () (窗口-位置->屏幕 (窗口-设置-位置 (窗口-打开 b1 2 80) (位置 1 1)))) list)
                '(1 1))
  (check-equal? (call-with-values (lambda () (窗口-位置->屏幕 (窗口-设置-位置 ww (位置 0 2)))) list)
                '(1 0))
  (check-equal? (call-with-values (lambda () (窗口-屏幕->位置 ww 1 0)) list)
                '(0 2))

  ;; 折行 视觉行滚动
  (check-equal? (let ([w (窗口-滚动 ww 1)]) (list (窗口-顶行 w) (窗口-顶段 w))) '(0 1))
  (check-equal? (let* ([w (窗口-滚动 ww 1)] [w (窗口-滚动 w 1)])
                  (list (窗口-顶行 w) (窗口-顶段 w))) '(1 0))
  (check-equal? (let* ([w (窗口-滚动 ww 2)] [w (窗口-滚动 w -1)])
                  (list (窗口-顶行 w) (窗口-顶段 w))) '(0 1))

  ;; 光标跟随（裁剪）
  (define b5 (文档-打开 "l1\nl2\nl3\nl4\nl5"))
  (check-equal? (窗口-顶行 (窗口-确保-位置 (窗口-设置-位置 (窗口-打开 b5 2 10) (位置 4 0)))) 3)
  (check-equal? (窗口-顶行 (窗口-确保-位置 (窗口-设置-顶行 (窗口-设置-位置 (窗口-打开 b5 2 10) (位置 0 0)) 3))) 0)
  ;; 水平跟随
  (check-equal? (窗口-左列 (窗口-确保-位置 (窗口-设置-位置 (窗口-打开 (文档-打开 "abcdefgh") 1 4) (位置 0 7)))) 4)
  (check-equal? (窗口-左列 (窗口-确保-位置 (窗口-设置-左列 (窗口-设置-位置 (窗口-打开 (文档-打开 "abcdefgh") 1 4) (位置 0 0)) 4))) 0)

  ;; 宽字符边界：绝不切半
  (check-equal? (窗口-左列 (窗口-确保-位置 (窗口-设置-位置 (窗口-打开 (文档-打开 "中中文中") 1 4) (位置 0 2)))) 2)
  (check-equal? (窗口-左列 (窗口-确保-位置 (窗口-设置-位置 (窗口-打开 (文档-打开 "abcdef中") 1 7) (位置 0 6)))) 1)

  ;; 光标跟随（折行）
  (define w7 (窗口-设置-模式 (窗口-设置-位置 (窗口-打开 (文档-打开 "中中中\nx") 2 4) (位置 1 0)) '折行))
  (check-equal? (let ([w (窗口-确保-位置 w7)]) (list (窗口-顶行 w) (窗口-顶段 w))) '(0 1))

  ;; 视觉行移动（折行 跨段）
  (define wv (窗口-设置-模式 (窗口-打开 (文档-打开 "中中中\nx") 3 4) '折行))
  (check-equal? (窗口-位置 (窗口-视觉-移动 wv +1)) (位置 0 2))
  (check-equal? (窗口-位置 (窗口-视觉-移动 (窗口-视觉-移动 wv +1) +1)) (位置 1 0))
  ;; 视觉列保持（裁剪 按显示列）
  (check-equal? (窗口-位置 (窗口-视觉-移动 (窗口-设置-位置 (窗口-打开 (文档-打开 "中ab\nabcd") 2 80) (位置 0 2)) +1))
                (位置 1 3))
  ;; 夹到段尾不溢出
  (check-equal? (窗口-位置 (窗口-视觉-移动 (窗口-设置-位置 (窗口-设置-模式 (窗口-打开 (文档-打开 "x\na中b") 2 2) '折行) (位置 0 1)) +1))
                (位置 1 0))

  ;; 夹紧-视口
  (define cv (窗口-设置-顶行 (窗口-打开 (文档-打开 "l0\nl1\nl2\nl3") 2 10) 50))
  (check-equal? (窗口-顶行 cv) 50)                 ; 设置-* 只做 max 0
  (check-equal? (窗口-顶行 (窗口-夹紧-视口 cv)) 2)
  (check-equal? (vector-ref (窗口-虚拟行集 (窗口-夹紧-视口 cv)) 0) (虚拟行 2 0 10))
  (check-true (vector? (窗口-虚拟行集 (窗口-夹紧-视口 (窗口-设置-模式 cv '折行)))))
  (check-equal? (窗口-左列 (窗口-夹紧-视口 (窗口-设置-左列 (窗口-打开 (文档-打开 "中abc") 3 4) 1))) 2)
  ;; 折行 + 行号栏：顶层行号越界（远超行数）也要夹回合法行，绝不崩
  (define wclamp (窗口-设置-模式 (窗口-设置-行号 (窗口-打开 (文档-打开 "0123456789\n0123456789\n0123456789") 1 2) #t) '折行))
  (define wclamped (窗口-夹紧-视口 (窗口-设置-顶行 wclamp 4)))
  (check-equal? (窗口-顶行 wclamped) 2)              ; n=3 → 最大行号 2
  (check-true (vector? (窗口-虚拟行集 wclamped)))

  ;; 行尾插入点占一格：光标不许落到窗口右边界之外
  ;; 裁剪：行宽 == 窗口宽，光标在行尾 → 右滚一格，光标落到最后一列
  (define 行尾-裁剪 (窗口-确保-位置 (窗口-设置-位置 (窗口-打开 (文档-打开 "0123456789") 1 10) (位置 0 10))))
  (check-equal? (窗口-左列 行尾-裁剪) 1)
  (check-equal? (call-with-values (lambda () (窗口-位置->屏幕 行尾-裁剪)) list) '(0 9))
  ;; 裁剪：行尾但行没填满 → 视口不动，光标就在行尾
  (define 行尾-短 (窗口-确保-位置 (窗口-设置-位置 (窗口-打开 (文档-打开 "abc") 1 10) (位置 0 3))))
  (check-equal? (窗口-左列 行尾-短) 0)
  (check-equal? (call-with-values (lambda () (窗口-位置->屏幕 行尾-短)) list) '(0 3))
  ;; 裁剪：光标在最后一列（不是行尾，下面还有字符）→ 不误滚
  (define lastcol (窗口-确保-位置 (窗口-设置-位置 (窗口-打开 (文档-打开 "0123456789") 1 10) (位置 0 9))))
  (check-equal? (窗口-左列 lastcol) 0)
  (check-equal? (call-with-values (lambda () (窗口-位置->屏幕 lastcol)) list) '(0 9))
  ;; 折行：一行正好填满一段 → 行尾插入点占下一视觉行
  (check-equal? (折行-段列表 "aaaa" 4) '((0 . 4) (4 . 4)))
  (check-equal? (折行-段列表 "aaaaaaaa" 4) '((0 . 4) (4 . 8) (8 . 8)))
  (check-equal? (折行-段列表 "aaa" 4) '((0 . 3)))          ; 没填满 → 不补空段
  (check-equal? (折行-段列表 "" 4) '((0 . 0)))
  (define 行尾-折行 (窗口-确保-位置 (窗口-设置-模式 (窗口-设置-位置 (窗口-打开 (文档-打开 "aaaa") 2 4) (位置 0 4)) '折行)))
  (check-equal? (call-with-values (lambda () (窗口-位置->屏幕 行尾-折行)) list) '(1 0))
  ;; 折行 高度 1：确保 把视口滚到行尾那一段
  (define 行尾-wrap1 (窗口-确保-位置 (窗口-设置-模式 (窗口-设置-位置 (窗口-打开 (文档-打开 "aaaa") 1 4) (位置 0 4)) '折行)))
  (check-equal? (list (窗口-顶行 行尾-wrap1) (窗口-顶段 行尾-wrap1)) '(0 1))
  (check-equal? (call-with-values (lambda () (窗口-位置->屏幕 行尾-wrap1)) list) '(0 0))
  ;; 未 确保 时也不返回越界列：宁可不出光标，也不画到窗口外
  (check-false (let-values ([(r c) (窗口-位置->屏幕 (窗口-设置-位置 (窗口-打开 (文档-打开 "0123456789") 1 10) (位置 0 10)))])
                 (or r c)))

  ;; 点级视觉运动（供 map 组合）
  (check-equal? (位置-下 ww (位置 0 0)) (位置 0 2))
  (check-equal? (位置-上 ww (位置 0 2)) (位置 0 0))

  ;; —— 行号栏宽度 / 正文宽度 ——
  (define long200 (文档-打开 (string-join (for/list ([i (in-range 200)]) (number->string i)) "\n")))
  (define wln (窗口-设置-行号 (窗口-打开 long200 3 10) #t))
  (check-equal? (窗口-边栏-宽度 wln) 2)                    ; 最大-line=3 → 1 位 +1 分隔
  (check-equal? (窗口-内容-宽度 wln) 8)
  (check-equal? (窗口-边栏-宽度 (窗口-设置-顶行 wln 99)) 4)   ; max=102 → 3 位 +1
  (check-equal? (窗口-边栏-宽度 (窗口-打开 long200 3 10)) 0)     ; 关闭 → 0
  (check-equal? (窗口-内容-宽度 (窗口-打开 long200 3 10)) 10)
  ;; 栏不得吃掉全部列
  (check-equal? (窗口-边栏-宽度 (窗口-设置-行号 (窗口-打开 (文档-打开 "x") 3 2) #t)) 1)
  (check-equal? (窗口-内容-宽度 (窗口-设置-行号 (窗口-打开 (文档-打开 "x") 3 2) #t)) 1)
  (check-equal? (窗口-边栏-宽度 (窗口-设置-行号 (窗口-打开 (文档-打开 "x") 3 1) #t)) 0)

  (displayln "view.rkt: all tests passed"))

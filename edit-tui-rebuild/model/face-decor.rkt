#lang racket

;;; layer  : model
;;; effect : 无（纯值 + 纯函数）
;;;
;;; model/face-decor.rkt —— 增量 face 装饰的协议与行级工具
;;;
;;; 这是“每个文档一份持续状态”的纯函数接口，不是 hook：
;;;
;;;   open   : path track -> (values state layer)
;;;   change : state layer face-ctx -> (values state layer dirty)
;;;
;;;   state  : 插件自己的纯数据（词法状态 / 上次光标 / #f）
;;;   layer  : track，行 payload = 每格一个 face（或 #f），与文本逐行对齐
;;;   dirty  : 本次要重写回 core face port 的行
;;;
;;; 为什么在 model 层：plugins / env 都要构造并持有它；effects/paint 负责
;;; 把它装进 document slot。这里不碰 buffer / view / history，只做纯值计算。
;;;
;;; CONSTRAINT: 以下三条是 decor 的硬契约（CONSTRAINTS §4.1）。
;;;   · change 必须是纯函数：不能原地改传入的 state / layer / 向量。
;;;     旧 document 可能还在 history 里，原地改会污染 undo。
;;;   · change 返回的 layer 必须与 new-text 逐行对齐：行数相同，
;;;     每行向量长度 = 该行字符数。
;;;   · 不方便写增量时返回 (dirty-all)，整篇重扫也是合法实现。
;;;
;;; 跨模块配合 / 特殊约束见 CONSTRAINTS.md §4。

(provide (struct-out face-decor)
         (struct-out face-ctx)
         (struct-out dirty)
         dirty-all
         dirty-lines
         dirty-union
         dirty-all?
         dirty-ls
         dirty->lines
         dirty-empty?
         changes->dirty-lines
         change-line-span
         scan-track
         blank-layer-track
         refresh-layer
         stateful-advance
         face-runs
         ;; 插件需要的纯 core 词汇（不直接 require core）
         track-of-list
         track->list
         track-ref
         track-length
         track-splice
         track-slice
         track-line-length
         change-before
         change-after
         change-post-range
         point-line
         point-column
         range-start
         range-end)

(require (except-in racket/list range)
         racket/match
         "../../core/text/base/track.rkt"
         "../../core/text/base/line.rkt"
         "../../core/text/base/change.rkt"
         "../../core/text/base/point.rkt"
         "../../core/text/base/range.rkt")

;;; ════════════════ 协议 ════════════════

(struct face-decor (id layer applies? open change) #:transparent)
;; id       : symbol
;; layer    : symbol
;; applies? : doc-meta -> boolean
;; open     : path track -> (values state layer)
;; change   : state layer face-ctx -> (values state layer dirty)

(struct face-ctx (old-text new-text changes dirty path cursor) #:transparent)
;; old-text / new-text : track
;; changes : (listof change)       本次编辑（空 = 纯光标推进）
;; dirty   : dirty                 changes 直接波及的整行（新坐标）
;; path    : path | #f
;; cursor  : (cons line col) | #f  当前主光标；编辑期 fork 时是 #f

;;; ════════════════ 脏区 ════════════════

;; 脏区 = 全脏（all?）或一组行号。显式类型，避免把“全脏”哨兵混进列表运算。
(struct dirty (all? ls) #:transparent)

(define (dirty-all) (dirty #t '()))
(define (dirty-lines lines) (dirty #f (sort (remove-duplicates lines) <)))
(define (dirty-empty? d) (and (not (dirty-all? d)) (null? (dirty-ls d))))

(define (dirty-union a b)
  (cond [(dirty-all? a) a]
        [(dirty-all? b) b]
        [else (dirty-lines (append (dirty-ls a) (dirty-ls b)))]))

;; 展开成具体行号，夹到 [0,n)。
(define (dirty->lines d n)
  (cond [(dirty-all? d) (for/list ([i (in-range n)]) i)]
        [else (filter (lambda (i) (< i n)) (dirty-ls d))]))

;;; ════════════════ change -> 脏行 ════════════════

;; 一条 change 的 after 区间覆盖的整行（前后都含；删除的零宽 after 也重扫该行）。
(define (change-line-span ch)
  (define r (change-post-range ch))
  (cons (point-line (range-start r)) (point-line (range-end r))))

(define (changes->dirty-lines changes)
  (dirty-lines
   (append* (for/list ([ch (in-list changes)])
              (define sp (change-line-span ch))
              (for/list ([i (in-range (car sp) (add1 (cdr sp)))]) i)))))

;;; ════════════════ 缓存 track ════════════════

;; 整篇扫描：scan : line-index string -> 行局部值。
(define (scan-track text scan)
  (track-of-list
   (for/list ([line (in-list (track->list text))] [i (in-naturals)])
     (scan i line))))

;; 与文本同形的全 #f 层（尚未上色 / 无状态的 decor 用）。
(define (blank-layer-track text)
  (track-of-list
   (for/list ([line (in-list (track->list text))])
     (make-vector (string-length line) #f))))

;; 只重扫脏行：把旧层中“编辑波及的结构区间”按 change 的 before→after 行区间
;; 替换成对新文本重扫的结果，其余行由 track 结构共享。
;;
;;   changes : (listof change)      本次编辑（before = 旧层坐标，after = 新文本坐标）
;;   extra   : (listof line-index)  额外内容脏行（新坐标，如活动词所在行）
(define (refresh-layer layer text changes extra scan)
  (define n (track-length text))
  ;; 每个 change → (list old-lo old-hi new-lo new-hi)，hi 开。
  (define spans
    (sort
     (for/list ([ch (in-list changes)])
       (define b (change-before ch))
       (define a (change-after ch))
       (list (point-line (range-start b)) (add1 (point-line (range-end b)))
             (point-line (range-start a)) (add1 (point-line (range-end a)))))
     > #:key car))
  ;; 结构替换从右到左：右侧替换不影响左侧的旧层行号。
  (define layer*
    (for/fold ([layer layer]) ([sp (in-list spans)])
      (match-define (list olo ohi nlo nhi) sp)
      (track-splice layer olo ohi
                    (for/list ([line (in-list (track-slice text nlo nhi))]
                               [i (in-naturals nlo)])
                      (scan i line)))))
  (define covered
    (for*/list ([sp (in-list spans)] [i (in-range (third sp) (fourth sp))]) i))
  (for/fold ([layer layer*]) ([ln (in-list (sort (remove-duplicates extra) <))])
    (if (or (>= ln n) (memv ln covered))
        layer
        (track-splice layer ln (add1 ln)
                      (list (scan ln (track-ref text ln)))))))

;;; ════════════════ 有状态行扫描的增量推进 ════════════════

;; 一次编辑的行区间 (old-lo old-hi new-lo new-hi)，hi 开；从右到左处理。
(define (change-spans changes)
  (sort
   (for/list ([ch (in-list changes)])
     (define b (change-before ch))
     (define a (change-after ch))
     (list (point-line (range-start b)) (add1 (point-line (range-end b)))
           (point-line (range-start a)) (add1 (point-line (range-end a)))))
   > #:key car))

;; 有状态行扫描的增量推进：states / layer 与文本逐行对齐。
;;   states[i] = 第 i 行的出状态；incoming(0) = init-state，incoming(i) = states[i-1]。
;;   scan : state line-no line -> (values state' payload)
;; 步骤：① 按 changes 把 states/layer 结构 splice 对齐（新行填 #f）；
;;       ② 从首个脏行起带状态重扫，直到出状态与旧值收敛（相同就可停）。
;; 返回 (values states' layer' dirty)。
(define (stateful-advance states layer text changes scan init-state)
  (define n (track-length text))
  (define-values (states0 layer0)
    (for/fold ([st states] [ly layer]) ([sp (in-list (change-spans changes))])
      (match-define (list olo ohi nlo nhi) sp)
      (define k (max 0 (- nhi nlo)))
      (values (track-splice st olo ohi (make-list k #f))
              (track-splice ly olo ohi (make-list k #f)))))
  (define seed (changes->dirty-lines changes))
  (define dls (if (dirty-empty? seed) '() (dirty->lines seed n)))
  (cond
    [(null? dls) (values states0 layer0 (dirty-lines '()))]
    [else
     ;; 从每个脏行 run 的起点带状态重扫；状态与旧值收敛就停。
     ;; 多个不相邻的 change：收敛后跳到下一个脏行，不把中间未变行重扫。
     (let loop ([pending dls] [st states0] [ly layer0] [dirty '()])
       (cond
         [(null? pending) (values st ly (dirty-lines (reverse dirty)))]
         [else
          (define lo (car pending))
          (define incoming (if (= lo 0) init-state (track-ref states0 (sub1 lo))))
          (let inner ([ln lo] [st st] [ly ly] [dirty dirty] [pending pending]
                      [incoming incoming])
            (cond
              [(>= ln n) (values st ly (dirty-lines (reverse dirty)))]
              [(and (pair? pending) (< (car pending) ln))
               (inner ln st ly dirty (cdr pending) incoming)]
              [else
               (define line (track-ref text ln))
               (define-values (out payload) (scan incoming ln line))
               (define st* (track-splice st ln (add1 ln) (list out)))
               (define ly* (track-splice ly ln (add1 ln) (list payload)))
               (define dirty* (cons ln dirty))
               (define pending* (if (and (pair? pending) (= ln (car pending)))
                                    (cdr pending)
                                    pending))
               (cond
                 [(equal? out (track-ref states0 ln))
                  ;; 本 run 收敛。若还有更远的脏行，从那里重新开始。
                  (if (null? pending*)
                      (values st* ly* (dirty-lines (reverse dirty*)))
                      (loop pending* st* ly* dirty*))]
                 [else (inner (add1 ln) st* ly* dirty* pending* out)])]))]))]))
;;; ════════════════ 行 face 向量 → 区间 ════════════════

;; vec : (vectorof (or/c face? #f))。→ (listof (list start end face))，face 非 #f。
(define (face-runs vec)
  (define n (vector-length vec))
  (let loop ([i 0] [acc '()])
    (cond
      [(>= i n) (reverse acc)]
      [else
       (define f (vector-ref vec i))
       (define j (let next ([j (add1 i)])
                   (if (and (< j n) (equal? (vector-ref vec j) f)) (next (add1 j)) j)))
       (loop j (if f (cons (list i j f) acc) acc))])))

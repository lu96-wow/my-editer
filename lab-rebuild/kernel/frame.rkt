#lang racket

;;; lab-rebuild/kernel/frame.rkt —— 主区编辑叶树 + 纯派生布局。
;;;
;;; 只存结构（root）；layout 是纯函数（area → (listof rectangle)）。
;;;   leaf(vid role) | split(dir size a b)
;;; dock / 焦点在 workspace.rkt；这里不认 dock。

(require "editor-api.rkt")

(provide (struct-out leaf) (struct-out split) (struct-out frame) (struct-out area)
         frame-empty frame-new frame-set-root
         frame-leaves frame-first-vid frame-find frame-contains?
         frame-split frame-remove frame-replace frame-swap frame-resize
         area-split frame->rectangles)

(struct area (x y w h) #:transparent)

;; 按 dir 把 area 切成两段（第一段 size）。
(define (area-split a dir size)
  (case dir
    [(lr) (values (area (area-x a) (area-y a) size (area-h a))
                  (area (+ (area-x a) size) (area-y a) (- (area-w a) size) (area-h a)))]
    [(tb) (values (area (area-x a) (area-y a) (area-w a) size)
                  (area (area-x a) (+ (area-y a) size) (area-w a) (- (area-h a) size)))]
    [else (error 'area-split "dir 必须是 'lr / 'tb")]))

(struct leaf (vid role) #:transparent)
(struct split (dir size a b) #:transparent)
(struct frame (root) #:transparent)
;; root : #f | leaf | split

(define (frame-empty) (frame #f))
(define (frame-new root) (frame root))
(define (frame-set-root f r) (frame r))

(define (frame-leaves f)
  (define (go n)
    (cond [(not n) '()]
          [(leaf? n) (list n)]
          [else (append (go (split-a n)) (go (split-b n)))]))
  (go (frame-root f)))

(define (frame-first-vid f)
  (define ls (frame-leaves f))
  (and (pair? ls) (leaf-vid (car ls))))

(define (frame-contains? f vid)
  (for/or ([l (in-list (frame-leaves f))]) (eqv? vid (leaf-vid l))))

(define (frame-find f vid)
  (for/first ([l (in-list (frame-leaves f))] #:when (eqv? vid (leaf-vid l))) l))

;; 把 vid 的叶换成 node(dir, leaf vid, leaf new-vid)——外层分屏。
(define (frame-split f vid dir new-vid [size #f])
  (define (go n)
    (cond
      [(not n) (leaf vid 'edit)]
      [(leaf? n)
       (if (eqv? (leaf-vid n) vid) (split dir size n (leaf new-vid 'edit)) n)]
      [else (struct-copy split n [a (go (split-a n))] [b (go (split-b n))])]))
  (frame (go (frame-root f))))

;; 删掉 vid 的叶；空 → #f。
(define (frame-remove f vid)
  (define (go n)
    (cond
      [(not n) #f]
      [(leaf? n) (if (eqv? (leaf-vid n) vid) #f n)]
      [else
       (define a (go (split-a n)))
       (define b (go (split-b n)))
       (cond [(and a b) (struct-copy split n [a a] [b b])]
             [a a] [b b] [else #f])]))
  (frame (go (frame-root f))))

;; 把 vid 所在的叶整体替换成 new-root（叶或 split）。
(define (frame-replace f vid new-root)
  (define (go n)
    (cond [(not n) #f]
          [(leaf? n) (if (eqv? (leaf-vid n) vid) new-root n)]
          [else (struct-copy split n [a (go (split-a n))] [b (go (split-b n))])]))
  (frame (go (frame-root f))))

;; 交换两个叶的 vid（位置不变）。
(define (frame-swap f v1 v2)
  (define (go n)
    (cond [(not n) #f]
          [(leaf? n) (cond [(eqv? (leaf-vid n) v1) (leaf v2 (leaf-role n))]
                           [(eqv? (leaf-vid n) v2) (leaf v1 (leaf-role n))]
                           [else n])]
          [else (struct-copy split n [a (go (split-a n))] [b (go (split-b n))])]))
  (frame (go (frame-root f))))

(define (node-contains? n vid)
  (cond [(leaf? n) (eqv? vid (leaf-vid n))]
        [else (or (node-contains? (split-a n) vid) (node-contains? (split-b n) vid))]))

;; 沿 vid 所在路径找最近的同向 split，把第一段尺寸调 delta。axis: 'width | 'height。
(define (frame-resize f vid axis delta area)
  (define target (if (eq? axis 'width) 'lr 'tb))
  (define (go node a)
    (cond
      [(leaf? node) node]
      [else
       (define dir (split-dir node))
       (define e (max 2 (if (eq? dir 'lr) (area-w a) (area-h a))))
       (define s (max 1 (or (split-size node) (quotient e 2))))
       (define in-a? (node-contains? (split-a node) vid))
       (define in-b? (node-contains? (split-b node) vid))
       (cond
         [(and (eq? dir target) (or in-a? in-b?))
          (struct-copy split node [size (max 1 (min (- e 2) (+ s (if in-a? delta (- delta)))))])]
         [else
          (define-values (a* b*) (area-split a dir s))
          (struct-copy split node
                       [a (if in-a? (go (split-a node) a*) (split-a node))]
                       [b (if in-b? (go (split-b node) b*) (split-b node))])])]))
  (frame (go (frame-root f) area)))

;; → (listof rectangle)。叶之间的 1 格 gap。
(define (frame->rectangles f reg)
  (define gap 1)
  (define (go n a)
    (cond
      [(not n) '()]
      [(leaf? n) (list (rectangle (leaf-vid n) (area-x a) (area-y a) (area-w a) (area-h a) 0))]
      [else
       (define dir (split-dir n))
       (define total (if (eq? dir 'lr) (area-w a) (area-h a)))
       (define size (max 1 (or (split-size n) (quotient (- total gap) 2))))
       (define-values (a* b) (area-split a dir size))
       (define b* (if (eq? dir 'lr)
                      (area (+ (area-x b) gap) (area-y b) (max 1 (- (area-w b) gap)) (area-h b))
                      (area (area-x b) (+ (area-y b) gap) (area-w b) (max 1 (- (area-h b) gap)))))
       (append (go (split-a n) a*) (go (split-b n) b*))]))
  (go (frame-root f) reg))

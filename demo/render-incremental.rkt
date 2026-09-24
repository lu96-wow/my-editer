#lang racket

;;; ============================================================================
;;; demo/render-incremental.rkt —— 增量渲染等价性测试（虚拟终端）
;;; ============================================================================
;;;
;;; 把 frame-damage 的补丁（脏矩形 + 修补绘制项）应用到一块「虚拟终端网格」，
;;; 结果必须与「整帧重绘」逐格一致。这样就能严格验证：
;;;   · 上一帧被光标/选区覆盖的位置有没有被正确还原；
;;;   · 多选区（多个 cursor / region）增删移动是否正确；
;;;   · 单窗格 与 多窗格合成 都覆盖。
;;;
;;;   racket demo/render-incremental.rkt

(require "../core/editor.rkt"
         "../core/api.rkt"
         "../core/target.rkt"
         rackunit)

;;; ---------- 虚拟终端网格 ----------

(define (grid H W) (for/vector ([_ (in-range H)]) (make-vector W (cons #\space #f))))

(define (display-char-at text c)          ; 文本显示列 c 上的字符（宽字符右半格同一字符）
  (define n (string-length text))
  (let loop ([i 0] [col 0])
    (cond [(>= i n) #\space]
          [else
           (define ch (string-ref text i))
           (define w (char-display-width ch))
           (cond [(zero? w) (loop (add1 i) col)]
                 [(and (<= col c) (< c (+ col w))) ch]
                 [else (loop (add1 i) (+ col w))])])))

(define (paint! g items)
  (define H (vector-length g))
  (for ([it (in-list items)])
    (define y (draw-item-y it))
    (define x (draw-item-x it))
    (for ([c (in-range (draw-item-width it))])
      (define col (+ x c))
      (when (and (>= y 0) (< y H) (>= col 0) (< col (vector-length (vector-ref g y))))
        (vector-set! (vector-ref g y) col
                     (cons (display-char-at (draw-item-text it) c) (draw-item-attr it)))))))

(define (clear-rects! g rects)
  (define H (vector-length g))
  (for ([r (in-list rects)])
    (for ([y (in-range (rect-y r) (+ (rect-y r) (rect-height r)))])
      (for ([x (in-range (rect-x r) (+ (rect-x r) (rect-width r)))])
        (when (and (>= y 0) (< y H) (>= x 0) (< x (vector-length (vector-ref g y))))
          (vector-set! (vector-ref g y) x (cons #\space #f)))))))

(define (full-grid H W screen)
  (define g (grid H W))
  (paint! g (frame->draw-list screen))
  g)

(define (apply-patch! g H W rects items)
  (if (not rects)
      (begin (clear-rects! g (for/list ([y (in-range H)]) (rect 0 y W 1))) (paint! g items))
      (begin (clear-rects! g rects) (paint! g items)))
  g)

;;; ---------- 操作序列（含多选区增删移动） ----------

(define (shift ed f) (editor-map-primary ed (lambda (s) (selection-map-head (lambda (p) (f ed p)) s))))
(define (edit1 ed op) (let-values ([(e _r) (editor-edit ed op)]) e))

(define DOC (string-join '("ab ab ab" "cd cd cd" "ef ef ef" "gh gh gh" "ij ij ij") "\n"))

(define steps
  (list
   (lambda (ed) (editor-set-selections ed (list (selection (point 0 0) (point 0 2)))))                    ; 单选区
   (lambda (ed) (editor-set-selections ed (list (selection (point 0 0) (point 0 2))                      ; 3 选区
                                                (selection (point 0 3) (point 0 5))
                                                (selection (point 1 0) (point 1 2)))))
   (lambda (ed) (editor-goto ed (point 2 1)))                                                            ; 塌缩到单光标
   (lambda (ed) (shift ed editor-point-right))                                                           ; Shift 扩选
   (lambda (ed) (shift ed editor-point-right))
   (lambda (ed) (editor-set-selections ed (list (selection (point 0 0) (point 1 0)))))                    ; 跨行选区
   (lambda (ed) (editor-goto ed (point 0 0)))
   (lambda (ed) (editor-set-selections ed (list (selection (point 0 0) (point 0 1))                      ; 多光标
                                                (selection (point 0 3) (point 0 4))
                                                (selection (point 0 6) (point 0 7)))))
   (lambda (ed) (edit1 ed (edit-insert "Z")))                                                            ; 多光标插入
   (lambda (ed) (editor-collapse-selections ed))
   (lambda (ed) (editor-set-selections ed (list (selection (point 1 0) (point 3 2)))))))                  ; 大范围跨行选区

;;; ---------- 单窗格：逐步增量 vs 全量 ----------

(define (drive-single H W)
  (define ed0 (editor-open DOC H W))
  (define p0 (window->projection (editor-view-window ed0 0)))
  (define s0 (projection-screen p0))
  (define g (full-grid H W s0))
  (for/fold ([ed ed0] [proj p0] [scr s0] [gr g]) ([f (in-list steps)] [i (in-naturals)])
    (define ed2 (f ed))
    (define-values (p dirty) (window->projection/incremental proj (editor-view-window ed2 0) '()))
    (define s2 (projection-screen p))
    (define-values (rects items) (frame-damage scr s2 dirty))
    (apply-patch! gr H W rects items)
    (check-equal? gr (full-grid H W s2) (format "单窗格 step ~a（增量补丁 != 全量）" i))
    (values ed2 p s2 gr)))

;;; ---------- 双窗格（合成）：逐步增量 vs 全量 ----------

(define (drive-double H PW RX)
  (define W (+ RX PW))
  (define ed0 (editor-open DOC H PW #:line-numbers? #t))
  (define-values (ed1 _v) (editor-add-view ed0 0 H PW #:sync 'follow #:line-numbers? #t))
  (define (proj ed vid) (window->projection (editor-view-window ed vid)))
  (define (panes p0 p1) (list (pane 0 0 0 (projection-screen p0))
                              (pane 1 RX 0 (projection-screen p1))))
  (define p0 (proj ed1 0)) (define p1 (proj ed1 1))
  (define comp (compose-panes H W (panes p0 p1) 0))
  (define g (full-grid H W (composition-screen comp)))
  (for/fold ([ed ed1] [pa p0] [pb p1] [cp comp] [gr g]) ([f (in-list steps)] [i (in-naturals)])
    (define ed2 (f ed))
    (define-values (pa2 da) (window->projection/incremental pa (editor-view-window ed2 0) '()))
    (define-values (pb2 db) (window->projection/incremental pb (editor-view-window ed2 1) '()))
    (define-values (cp2 cd) (composition-refresh cp H W (panes pa2 pb2) 0 (hash 0 da 1 db)))
    (define s2 (composition-screen cp2))
    (define-values (rects items) (frame-damage (composition-screen cp) s2 cd))
    (apply-patch! gr H W rects items)
    (check-equal? gr (full-grid H W s2) (format "双窗格 step ~a（增量补丁 != 全量）" i))
    (values ed2 pa2 pb2 cp2 gr)))

;;; ---------- 跑 ----------

(printf "单窗格：~a 步\n" (length steps))
(call-with-values (lambda () (drive-single 5 20)) (lambda _ (void)))
(printf "双窗格：~a 步\n" (length steps))
(call-with-values (lambda () (drive-double 5 12 13)) (lambda _ (void)))
(printf "render-incremental: all equivalent（增量 == 全量）\n")

(module+ test
  (check-true (begin (call-with-values (lambda () (drive-single 5 20)) (lambda _ #t)) #t))
  (check-true (begin (call-with-values (lambda () (drive-double 5 12 13)) (lambda _ #t)) #t)))

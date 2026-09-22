#lang racket

(require "../atom/point.rkt" "../atom/selection.rkt" "../atom/width.rkt"
         "../doc/buffer.rkt" "../doc/document.rkt" "window.rkt" "../unit/screen.rkt" "layout.rkt" "render.rkt"
         rackunit)

;;; viewport/project.rkt —— 把 window 的可见区投影成 screen（纯函数）
;;;
;;; 两条通道分开投影：
;;;   文档文本   window-vrows → line-range->runs → row-runs
;;;   视图 overlay  window-selections → 光标点（head）/ 选中区段（[anchor,head) 按 vrow 切）
;;; 真正的绘制在后端；这里只给屏幕坐标 + 语义 face。

(provide window->screen)

;; 一个选区在**某一行**的显示列区间 (list start end)，不在该行 → #f。
(define (selection-range-on-line b sl sc el ec line)
  (define text (buffer-line-ref b line))
  (cond
    [(and (= line sl) (= line el)) (list (index->column text sc) (index->column text ec))]
    [(= line sl)                   (list (index->column text sc) (string-display-width text))]
    [(= line el)                   (list 0 (index->column text ec))]
    [(and (> line sl) (< line el)) (list 0 (string-display-width text))]
    [else #f]))

;; 一个选区 → 若干屏幕区间段（每个可见 vrow 至多一段）。空选区 → '()。
(define (selection->regions w sel)
  (define b (window-buffer w))
  (define-values (s e) (selection-range sel))
  (define sl (point-line s)) (define sc (point-col s))
  (define el (point-line e)) (define ec (point-col e))
  (define vrows (window-vrows w))
  (for/list ([vr (in-vector vrows)] [row (in-naturals)])
    (define ln (vrow-line vr))
    (define rng (and (>= ln 0) (selection-range-on-line b sl sc el ec ln)))
    (if rng
        (let* ([a (car rng)] [z (cadr rng)]
               [s* (max a (vrow-start-col vr))]
               [e* (min z (vrow-end-col vr))])
          (and (< s* e*)
               (region row (- s* (vrow-start-col vr)) (- e* (vrow-start-col vr))
                       (hash 'face 'selection))))
        #f)))

(define (window->screen w [face-provider empty-face-provider])
  (define b (window-buffer w))
  (define vrows (window-vrows w))
  (define g (window-gutter-width w))
  (define row-runs
    (for/vector ([vr (in-vector vrows)] [row (in-naturals)])
      (define content
        (if (and (>= (vrow-line vr) 0) (< (vrow-start-col vr) (vrow-end-col vr)))
            (line-range->runs b (vrow-line vr) (vrow-start-col vr) (vrow-end-col vr) face-provider)
            '()))
      (define gutter
        (cond
          [(zero? g) '()]
          [(and (>= (vrow-line vr) 0) (vrow-first-for-line? vrows row))
           (list (line-number-run (add1 (vrow-line vr)) g))]
          [else (list (blank-gutter-run g))]))
      (append gutter (map (lambda (rn) (shift-run rn g)) content))))
  ;; 视图 overlay：光标 = 每个选区的 head（列 +g → 屏幕绝对列）
  (define cursors
    (filter values
            (for/list ([s (in-list (window-selections w))] [i (in-naturals)])
              (define-values (r c) (window-point->screen w (selection-point s)))
              (and r (cursor r (+ g c) (hash 'face 'cursor) (= i (window-primary-index w)))))))
  ;; 视图 overlay：选中区 = 每个非空选区的 [anchor,head)
  (define selections
    (for/list ([rg (in-list (filter values (append* (for/list ([s (in-list (window-selections w))])
                                                      (selection->regions w s))))) ])
      (region (region-row rg) (+ g (region-start-col rg)) (+ g (region-end-col rg)) (region-face rg))))
  (screen (window-height w) (window-width w) row-runs cursors selections))

;;; ---------- 行号栏（视图装饰，不属文档） ----------

;; 该 vrow 是否是它那条 buffer 行的首段（wrap 下只有首段显示行号）。
(define (vrow-first-for-line? vrows row)
  (or (= row 0)
      (not (= (vrow-line (vector-ref vrows row))
              (vrow-line (vector-ref vrows (sub1 row)))))))

;; 行号栏一格：数字右对齐到 g-1 列 + 1 分隔空格；col 固定 0（正文整体右移 g）。
(define (line-number-run n g)
  (define s (number->string n))
  (run 0 (string-append (make-string (- g 1 (string-length s)) #\space) s " ")
       (hash 'face 'line-number)))
(define (blank-gutter-run g) (run 0 (make-string g #\space) (hash 'face 'line-number)))
(define (shift-run rn x) (run (+ x (run-col rn)) (run-text rn) (run-face rn)))

;;; ---------- 测试 ----------

(module+ test
  (define b0 (document-open "a中b\nc"))

  ;; 基本投影：文档 runs + primary 光标；空选区不出区间
  (define s0 (window->screen (window-open b0 2 10)))
  (check-equal? (screen-row s0 0) (list (run 0 "a中b" (hash))))
  (check-equal? (screen-row s0 1) (list (run 0 "c" (hash))))
  (check-equal? (screen-cursor-row s0) 0)
  (check-equal? (screen-cursor-col s0) 0)
  (check-equal? (map (lambda (c) (list (cursor-row c) (cursor-col c) (cursor-primary? c))) (screen-cursors s0))
                '((0 0 #t)))
  (check-equal? (screen-selections s0) '())                    ; 空选区不出区间

  ;; 光标显示列
  (check-equal? (screen-cursor-col (window->screen (window-set-point (window-open b0 2 10) (point 0 2)))) 3)

  ;; 选中区：跨宽字符 → 显示列区间；另一行是空光标
  (define ws (window-open (document-open "abcdef\nghij") 3 10))
  (define wsel (window-set-selections ws (list (selection (point 0 1) (point 0 4))
                                               (selection (point 1 0) (point 1 2)))))
  (define ss (window->screen wsel))
  (check-equal? (map (lambda (c) (list (cursor-row c) (cursor-col c) (cursor-primary? c))) (screen-cursors ss))
                '((0 4 #t) (1 2 #f)))
  (check-equal? (map (lambda (g) (list (region-row g) (region-start-col g) (region-end-col g)))
                     (screen-selections ss))
                '((0 1 4) (1 0 2)))

  ;; wrap：一行折成两段，选中区切成两段
  (define ww (window-set-mode (window-set-selections (window-open (document-open "中中中") 3 4)
                                                     (list (selection (point 0 0) (point 0 3))))
                              'wrap))
  (check-equal? (map (lambda (g) (list (region-row g) (region-start-col g) (region-end-col g)))
                     (screen-selections (window->screen ww)))
                '((0 0 4) (1 0 2)))                          ; "中中" + "中"

  ;; 派生 face 分段（投影 provider，不进文档）
  (define (provider _b line) (if (zero? line) (list (list 0 1 (hash 'face 'bold))) '()))
  (check-equal? (screen-row (window->screen (window-open b0 2 10) provider) 0)
                (list (run 0 "a" (hash 'face 'bold)) (run 1 "中b" (hash))))

  ;; 属性不进 face
  (define b5 (document-put-attr (document-open "abcdef")
                              (point 0 3) (point 0 6) read-only-key #t))
  (check-equal? (screen-row (window->screen (window-open b5 1 10)) 0)
                (list (run 0 "abcdef" (hash))))

  ;; —— 行号栏：run 前缀 + 光标/选区右移 + 点 gutter 落行首 ——
  (define dln (document-open "a\nb\nc"))
  (define wln2 (window-set-line-numbers (window-open dln 3 10) #t))   ; g = 1 位 +1 = 2
  (define sln (window->screen wln2))
  (check-equal? (screen-row sln 0)
                (list (run 0 "1 " (hash 'face 'line-number)) (run 2 "a" (hash))))
  (check-equal? (screen-row sln 2)
                (list (run 0 "3 " (hash 'face 'line-number)) (run 2 "c" (hash))))
  (check-equal? (screen-cursor-col sln) 2)                         ; (0,0) → 屏幕列 2
  (check-equal? (call-with-values (lambda () (window-screen->point wln2 0 0)) list) '(0 0))  ; gutter → 行首

  ;; wrap：只有 buffer 行首段显示行号，续段/空行留空
  (define wlnw (window-set-line-numbers (window-set-mode (window-open (document-open "abcdefgh") 3 4) 'wrap) #t))
  (define sww (window->screen wlnw))                               ; g=2 → 正文宽 2
  (check-equal? (screen-row sww 0)
                (list (run 0 "1 " (hash 'face 'line-number)) (run 2 "ab" (hash))))
  (check-equal? (screen-row sww 1)
                (list (run 0 "  " (hash 'face 'line-number)) (run 2 "cd" (hash))))

  ;; 行号栏让出的宽度影响折行：宽 6、g=2 → 正文宽 4
  (define wln3 (window-set-line-numbers (window-set-mode (window-open (document-open "abcdefgh") 3 6) 'wrap) #t))
  (check-equal? (window-content-width wln3) 4)
  (check-equal? (map vrow-end-col (vector->list (window-vrows wln3))) '(4 8 8))

  (displayln "project.rkt: all tests passed"))

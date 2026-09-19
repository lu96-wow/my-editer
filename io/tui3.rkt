#lang racket

;;; io/tui3.rkt —— 三窗口示范：同一个 document 的三个视图
;;;
;;;   ┌───────────────┬───────────────┐
;;;   │               │  视图1 follow │   ← 同步：镜像编辑视图的光标 + 视口
;;;   │   视图0 free  ├───────────────┤
;;;   │   （主编辑）  │  视图2 free   │   ← 不同步：只映射光标，视口钉住
;;;   └───────────────┴───────────────┘
;;;
;;; 三个视图共享同一个 buffer（core 的 document 不变量）。在活动视图里编辑，
;;; follow 视图会跟着滚，free 视图不动——屏幕下面状态行的三个 top 行号能直接看出来。
;;;
;;; 运行：  racket io/tui3.rkt [文件]
;;; 按键：  可打印键/中文 插入   Enter 换行   Backspace/Delete 删除
;;;         ←→↑↓ Home End PgUp PgDn 导航   Tab 切换活动窗口
;;;         鼠标点击切换+定位   Ctrl+Z 撤销   Ctrl+Y 重做   Ctrl+Q / Esc 退出

(require "../core/api.rkt"
         "../core/compose/editor.rkt"
         tui
         racket/string
         racket/path)

;;; ---------- face → 终端样式 ----------

(define (face-style face)
  (case (hash-ref face 'face #f)
    [(keyword) 'info]
    [(comment) 'green]
    [(string)  'yellow]
    [(error)   'error]
    [else #f]))

(define keyword-rx #px"\\b(define|lambda|if|cond|let|for|match|and|or|not|else)\\b")

(define (rehighlight s)
  (define doc (editor-document s))
  (define n (document-line-count doc))
  (define segs
    (append*
     (for/list ([line (in-range n)])
       (define text (document-line-ref doc line))
       (for/list ([m (in-list (regexp-match-positions* keyword-rx text))])
         (list line (car m) (cdr m) 'keyword)))))
  (struct-copy editor s
    [document (document-apply-patches doc (list (patch 'face 0 (sub1 n) segs)))]))

;;; ---------- 布局（都 0-based，单位是屏幕行列）----------
;; 预算出各窗格尺寸，并保留 1 列 + 1 行分隔线。

(define (layout rows cols)
  (define H (max 3 (- rows 1)))                       ; 留最后一行做状态栏
  (define leftW (max 1 (min (quotient cols 2) (- cols 2))))
  (define rightW (max 1 (- cols leftW 1)))
  (define topH (max 1 (quotient (sub1 H) 2)))
  (define botH (max 1 (- H topH 1)))
  (values H leftW rightW topH botH))

;;; ---------- 渲染 ----------

;; name : 状态栏显示；tops : 三个视图各自 top-line（用来肉眼验证 follow/free）
(define (render-frame s rows cols name)
  (define-values (H leftW rightW topH botH) (layout rows cols))
  (define doc (editor-document s))
  (define scr (screen-compose
               H cols
               (list (list 0 0 0 (window->screen (document-window doc 0)))
                     (list 1 (add1 leftW) 0 (window->screen (document-window doc 1)))
                     (list 2 (add1 leftW) (+ topH 1) (window->screen (document-window doc 2))))
               (editor-active s)))
  (define parts (list format-cursor-hide format-screen-clear))
  (define (emit! b) (set! parts (cons b parts)))
  (for ([runs (in-vector (screen-row-runs scr))] [row (in-naturals)])
    (for ([r (in-list runs)])
      (emit! (format-cursor-move (add1 row) (add1 (run-col r))))
      (define st (face-style (run-face r)))
      (emit! (if st (format-styled st (run-text r)) (format-content (run-text r))))))
  ;; 分隔线：竖线在列 leftW，横线在行 topH
  (for ([row (in-range H)])
    (emit! (format-cursor-move (add1 row) (add1 leftW)))
    (emit! (format-content "│")))
  (for ([col (in-range (add1 leftW) cols)])
    (emit! (format-cursor-move (add1 topH) (add1 col)))
    (emit! (format-content "─")))
  (emit! (format-cursor-move (add1 topH) (add1 leftW)))
  (emit! (format-content "├"))
  ;; 状态行：三个 top 行号 + 活动窗格
  (define p (window-point (editor-window s)))
  (define doc* (editor-document s))
  (define (top i) (window-top-line (document-window doc* i)))
  (define status
    (format " ~a  L~a:C~a  tops(~a,~a,~a)  active=~a   Tab pane  ^Z ^Y  ^Q"
            name
            (add1 (point-line p)) (add1 (point-col p))
            (top 0) (top 1) (top 2) (editor-active s)))
  (emit! (format-cursor-move rows 1))
  (emit! (format-styled 'status-bar
                        (if (>= (string-length status) cols)
                            (substring status 0 (max 0 cols))
                            (string-append status (make-string (- cols (string-length status)) #\space)))))
  ;; 光标跟着活动窗格（screen-compose 已把 active 的光标平移好）
  (define cr (screen-cursor-row scr))
  (define cc (screen-cursor-col scr))
  (if (>= cr 0)
      (begin (emit! (format-cursor-move (add1 cr) (add1 cc))) (emit! format-cursor-show))
      (emit! format-cursor-hide))
  (apply bytes-append (reverse parts)))

;;; ---------- 入口 ----------

(define (run [path #f])
  (with-tui
   (lambda ()
     (enable-mouse!)
     (enable-bracketed-paste!)
     (define-values (r0 c0) (get-window-size))
     (define rows (max 4 r0))
     (define cols (max 6 c0))
     (define text (if (and path (file-exists? path)) (file->string path) ""))
     (define name (if path (path->string (file-name-from-path path)) "*scratch*"))
     (define-values (H leftW rightW topH botH) (layout rows cols))
     ;; 一个 document，三个视图：0=free（主），1=follow（右上），2=free（右下）
     (define doc0 (document-open text))
     (define-values (doc1 _i0) (document-add-view doc0 H leftW))
     (define-values (doc2 _i1) (document-add-view doc1 topH rightW #:sync 'follow))
     (define-values (doc3 _i2) (document-add-view doc2 botH rightW))
     (define s (rehighlight (editor-of-document doc3 0)))
     (define running? #t)

     (define (active) (editor-active s))
     (define (edit-op op)
       (set! s (let-values ([(s* report) (compose-edit s op)])
                 (if report (rehighlight s*) s*))))
     (define (navigate f)
       (set! s (struct-copy editor s
                 [document (document-update-view (editor-document s) (active) f)])))
     (define (move f) (navigate (lambda (w) (window-ensure-point (f w)))))
     (define (undo) (set! s (let-values ([(s* _) (compose-undo s)]) (rehighlight s*))))
     (define (redo) (set! s (let-values ([(s* _) (compose-redo s)]) (rehighlight s*))))
     (define (set-point! i pt)
       (set! s (struct-copy editor s
                 [document (document-update-view (editor-document s) i
                                                 (lambda (w) (window-set-point w pt)))])))
     (define (resize! nr nc)
       (set! rows (max 4 nr)) (set! cols (max 6 nc))
       (define-values (H leftW rightW topH botH) (layout rows cols))
       (define doc* (editor-document s))
       (set! s (struct-copy editor s
                 [document (document-set-view-size
                            (document-set-view-size
                             (document-set-view-size doc* 0 H leftW) 1 topH rightW)
                            2 botH rightW)])))
     (define (redraw) (put-bytes (render-frame s rows cols name)))

     ;; 屏幕坐标 → 窗格下标
     (define (pane-at x y)
       (define-values (H leftW rightW topH botH) (layout rows cols))
       (cond [(and (< x leftW) (< y H)) 0]
             [(and (>= x (add1 leftW)) (< y topH)) 1]
             [(and (>= x (add1 leftW)) (>= y (+ topH 1)) (< y H)) 2]
             [else #f]))

     (define handler
       (build-input
        #:utf-char (lambda (str) (edit-op (edit-insert str)))
        #:char     (lambda (ch)  (edit-op (edit-insert (string (integer->char ch)))))
        #:enter    (lambda ()    (edit-op (edit-newline)))
        #:backspace (lambda ()   (edit-op (edit-backspace)))
        #:delete   (lambda ()    (edit-op (edit-delete)))
        #:tab      (lambda ()    (set! s (editor-set-active s (modulo (add1 (active)) 3))))
        #:left (lambda () (move window-left))
        #:right (lambda () (move window-right))
        #:up (lambda () (move window-up))
        #:down (lambda () (move window-down))
        #:home (lambda () (move window-home))
        #:end (lambda () (move window-end))
        #:pageup   (lambda ()    (navigate (lambda (w) (window-scroll-visual w (- (window-height w))))))
        #:pagedown (lambda ()    (navigate (lambda (w) (window-scroll-visual w (window-height w)))))
        #:ctrl     (lambda (ch)
                     (case ch
                       [(#\Z) (undo)]
                       [(#\Y) (redo)]
                       [(#\Q) (set! running? #f)]
                       [else (void)]))
        #:escape   (lambda () (set! running? #f))
        #:paste    (lambda (data) (edit-op (edit-insert (bytes->string/utf-8 data))))
        #:mouse-press (lambda (_b x y _m)
                        (define pane (pane-at x y))
                        (when pane
                          (set! s (editor-set-active s pane))
                          (define-values (H leftW rightW topH botH) (layout rows cols))
                          (define ox (if (= pane 0) 0 (add1 leftW)))
                          (define oy (cond [(= pane 2) (+ topH 1)] [else 0]))
                          (define-values (l c)
                            (window-screen->point (document-window (editor-document s) pane)
                                                  (- y oy) (- x ox)))
                          (when l (set-point! pane (point l c)))))
        #:mouse-scroll (lambda (dir _x _y _m)
                         (navigate (lambda (w) (window-scroll-visual w (if (eq? dir 'up) -3 3)))))
        #:resize   (lambda (nr nc) (resize! nr nc))))

     (define (step type data mods) (handler type data mods) (redraw))
     (redraw)
     (loop-input/stop (not running?) step))))

;;; ---------- 无终端：合成 + 渲染冒烟 ----------

(module+ test
  (require rackunit)
  (define-values (doc0 _t0) (document-add-view (document-open "l0\nl1\nl2\nl3\nl4") 4 10))
  (define-values (doc1 _t1) (document-add-view doc0 2 8 #:sync 'follow))
  (define-values (doc2 _t2) (document-add-view doc1 2 8))
  (define s (rehighlight (editor-of-document doc2 0)))
  (define frame (render-frame s 10 24 "demo"))
  (check-true (bytes? frame))
  (check-true (regexp-match? #rx"l0" frame))
  (check-true (regexp-match? #rx"tops" frame))
  (displayln "tui3.rkt: render smoke test passed"))

(module+ main
  (define args (current-command-line-arguments))
  (run (and (> (vector-length args) 0) (vector-ref args 0))))

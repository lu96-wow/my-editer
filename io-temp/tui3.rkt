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

(require "../core/editor.rkt"
         "editor-ui.rkt"
         ;; tui 也导出 key-event/resize-event 等事件结构体，与 core 同名；
         ;; 这里用 core 的，排除 tui 的。
         (except-in tui key-event key-event? key-event-key struct:key-event
                    resize-event resize-event? resize-event-rows resize-event-cols
                    struct:resize-event)
         racket/string
         racket/path)

;; face / 高亮 / 命令封装 / Ctrl 映射 / 画帧原语都在 io/editor-ui.rkt。

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
  (define scr (screen-compose
               H cols
               (list (list 0 0 0 (editor-view->screen s 0))
                     (list 1 (add1 leftW) 0 (editor-view->screen s 1))
                     (list 2 (add1 leftW) (+ topH 1) (editor-view->screen s 2)))
               (editor-focus s)))
  (define parts (list format-cursor-hide format-screen-clear))
  (define (emit! b) (set! parts (cons b parts)))
  (draw-runs! emit! scr)
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
  (define p (editor-point s))
  (define (top i) (editor-view-top-line s i))
  (define status
    (format " ~a  L~a:C~a  tops(~a,~a,~a)  active=~a   Tab pane  ^Z ^Y  ^Q"
            name
            (add1 (point-line p)) (add1 (point-col p))
            (top 0) (top 1) (top 2) (editor-focus s)))
  (emit! (format-cursor-move rows 1))
  (emit! (format-styled 'status-bar
                        (if (>= (string-length status) cols)
                            (substring status 0 (max 0 cols))
                            (string-append status (make-string (- cols (string-length status)) #\space)))))
  (draw-cursor! emit! scr)
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
     ;; 三个视图：0=free（主），1=follow（右上），2=free（右下）；同一 buffer（id 0）
     (define ed0 (editor-open text H leftW #:name name))
     (define-values (ed1 _a0) (editor-add-view ed0 0 topH rightW #:sync 'follow))
     (define-values (ed2 _a1) (editor-add-view ed1 0 botH rightW))
     (define s (rehighlight (editor-focus-view ed2 0)))
     (define running? #t)

     (define (active) (editor-focus s))
     (define (edit-op op) (define-values (s* _) (edit-step s op)) (set! s s*))
     (define (undo) (define-values (s* _) (undo-step s)) (set! s s*))
     (define (redo) (define-values (s* _) (redo-step s)) (set! s s*))
     (define (set-point! i pt) (set! s (editor-view-set-point s i pt)))
     (define (resize! nr nc)
       (set! rows (max 4 nr)) (set! cols (max 6 nc))
       (define-values (H leftW rightW topH botH) (layout rows cols))
       (set! s (editor-view-set-size
                (editor-view-set-size (editor-view-set-size s 0 H leftW) 1 topH rightW)
                2 botH rightW)))
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
        ;; 新 API：文本统一走 #:text（可打印字符 + 粘贴），收 string
        #:text     (lambda (str) (edit-op (edit-insert str)))
        #:enter    (lambda ()    (edit-op (edit-newline)))
        #:backspace (lambda ()   (edit-op (edit-backspace)))
        #:delete   (lambda ()    (edit-op (edit-delete)))
        #:tab      (lambda ()    (set! s (editor-focus-view s (modulo (add1 (editor-focus s)) 3))))
        #:left (lambda () (set! s (editor-left s)))
        #:right (lambda () (set! s (editor-right s)))
        #:up (lambda () (set! s (editor-up s)))
        #:down (lambda () (set! s (editor-down s)))
        #:home (lambda () (set! s (editor-home s)))
        #:end (lambda () (set! s (editor-end s)))
        #:pageup   (lambda ()    (set! s (editor-scroll s (- (editor-height s)))))
        #:pagedown (lambda ()    (set! s (editor-scroll s (editor-height s))))
        ;; Ctrl 组合走 #:key（key + mods）；无修饰的字符已由 #:text 接走
        #:key      (lambda (key mods)
                     (case (ctrl-action key mods)
                       [(undo) (undo)]
                       [(redo) (redo)]
                       [(quit) (set! running? #f)]
                       [else (void)]))
        #:escape   (lambda () (set! running? #f))
        #:mouse    (lambda (action button x y _mods)
                     (case action
                       [(press)
                        (define pane (pane-at x y))
                        (when pane
                          (set! s (editor-focus-view s pane))
                          (define-values (H leftW rightW topH botH) (layout rows cols))
                          (define ox (if (= pane 0) 0 (add1 leftW)))
                          (define oy (cond [(= pane 2) (+ topH 1)] [else 0]))
                          (define-values (l c)
                            (editor-view-screen->point s pane (- y oy) (- x ox)))
                          (when l (set-point! pane (point l c))))]
                       [(scroll)
                        (set! s (editor-scroll s (if (eq? button 'up) -3 3)))]
                       [else (void)]))
        #:resize   (lambda (nr nc) (resize! nr nc))))

     (define (step ev) (handler ev) (redraw))
     (redraw)
     (loop-input/stop (not running?) step))))

;;; ---------- 无终端：合成 + 渲染冒烟 ----------

(module+ test
  (require rackunit)
  (define ed0 (editor-open "l0\nl1\nl2\nl3\nl4" 4 10))
  (define-values (ed1 _t1) (editor-add-view ed0 0 2 8 #:sync 'follow))
  (define-values (ed2 _t2) (editor-add-view ed1 0 2 8))
  (define s (rehighlight (editor-focus-view ed2 0)))
  (define frame (render-frame s 10 24 "demo"))
  (check-true (bytes? frame))
  (check-true (regexp-match? #rx"l0" frame))
  (check-true (regexp-match? #rx"tops" frame))
  ;; 局部重标：改掉关键字后旧 face 被清掉（patch 的"清旧写新"）
  (define sh (rehighlight (editor-open "(define x 42)" 4 20)))
  (check-equal? (editor-get-property sh (editor-focused-buffer-id sh) (point 0 1) 'face) 'keyword)
  (define-values (sh2 report) (editor-edit sh (edit-splice (point 0 0) (point 0 7) "print  ")))
  (define sh3 (apply-report sh2 report))
  (check-equal? (editor-get-property sh3 (editor-focused-buffer-id sh3) (point 0 1) 'face) #f)
  (check-equal? (change-report-first-line report) 0)
  (displayln "tui3.rkt: render smoke test passed"))

(module+ main
  (define args (current-command-line-arguments))
  (run (and (> (vector-length args) 0) (vector-ref args 0))))

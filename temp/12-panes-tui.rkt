#lang racket
;;; 12 —— 交互 demo（真 racket-tui 终端）：panel + pane 拼一屏，按任意键退出
;;;
;;; 运行：racket temp/12-panes-tui.rkt
;;;
;;; 终端尺寸从 get-window-size 取；窗口 resize 会重排。链条同 11-panes.rkt：
;;;   buffer/view → panel → entries/decorations → render-display-patch
;;;             → render-pieces → put-bytes（真后端）
;;;
;;; 无 tty 的 CI 里只跑 module+ test 的纯渲染部分：raco test temp/12-panes-tui.rkt

(require tui
         "../core/editor.rkt"
         "../edit-tui/theme/main.rkt"        ; require 即安装主题（face 符号 → 样式）
         "../edit-tui/layout-base/main.rkt"
         "../edit-tui/core-render/main.rkt")

;; 纯渲染入口，供测试 / 无 tty 环境调用
(provide frame-screen)

;;; ---------- 内容：三份文档 / 三个 view ----------

(define tree-b (make-buffer "src/\n  main.rkt\n  util.rkt\n  pane.rkt\n  render.rkt\nREADME.md" "*tree*"))
(define doc-b  (make-buffer
                "(define (f x)\n  ;; popup 盖在上面，deep 更高\n  (+ x 1))\n\n(f 41)\n"
                "main.rkt"))
(define pop-b  (make-buffer "popup\non top\n(deep 10)\n" "*popup*"))

(define tree-v (buffer-add-view! tree-b 18 10 #:line-numbers? #t))
(define doc-v  (buffer-add-view! doc-b  51 10 #:line-numbers? #t))
(define pop-v  (buffer-add-view! pop-b  18 4))

(define (node->view o)
  (case o [(tree) tree-v] [(doc) doc-v] [(popup) pop-v] [else #f]))

;;; ---------- 布局：按给定 W/H 排三块 panel ----------
;;;
;;; tree 右边界 + doc 不画左边 → 中间只有一条分隔线；
;;; 跨 panel 的 T（顶/底的 ┬ ┴）由 core-render 的全局边收集算出。

(define (layout W H)
  (define tw (min 20 (max 6 (- W 12))))            ; 左侧树宽
  (define tree-p (make-panel 'tree (rect 0 0 tw H) '(up down right)))
  (define doc-p  (make-panel 'doc  (rect tw 0 (max 1 (- W tw)) H) '(up down right)))
  (define pw (min 30 (max 8 (- W 6))))             ; 浮窗
  (define ph (min 8  (max 3 (- H 2))))
  (define px (max tw (quotient (- W pw) 2)))
  (define py (max 1 (quotient (- H ph) 2)))
  (define pop-p (make-panel 'popup (rect px py pw ph) borders-all
                            #:deep 10 #:face 'float-border))
  (define panels (list tree-p doc-p pop-p))
  ;; view 尺寸 = panel 内容区尺寸
  (for ([p (in-list panels)])
    (define c (panel-content p))
    (define v (node->view (panel-owner p)))
    (when v (view-resize! v (max 1 (rect-w c)) (max 1 (rect-h c)))))
  (values (panels->entries panels node->view) doc-v (panels->decorations panels)))

;; 纯渲染（测试 / 无 tty 可用）
(define (frame-screen W H)
  (define-values (entries focus decorations) (layout W H))
  (render-display entries focus W H decorations))

;;; ---------- 真终端一帧 ----------

(define (draw!)
  (define-values (rows cols) (get-window-size))
  (define R (or rows 24))
  (define C (or cols 80))
  (define H (max 4 (- R 1)))                       ; 留最后一行放提示
  (define W (max 16 C))
  (define-values (entries focus decorations) (layout W H))
  (define-values (_frame rends sels)
    (render-display-patch entries focus W H #f decorations))
  (put-bytes (bytes-append (render-clear) (render-pieces (append rends sels))))
  (put-bytes (format-cursor-move R 1))
  (put-string "  按任意键退出 · 拖动窗口可改变大小")
  (flush!))

(module+ main
  (with-tui
   (λ ()
     (cursor-hide)
     (draw!)
     (let loop ()
       (define ev (read-event))
       (cond
         [(resize-event? ev) (draw!) (loop)]        ; 改尺寸 → 重排重画
         [(null-event? ev)   (loop)]                ; 空事件不算键
         [else (void)])))))                         ; 任意键 → 退出

(module+ test
  (require rackunit)
  (define s (frame-screen 72 20))
  (check-equal? (screen-width s) 72)
  (check-equal? (screen-height s) 20)
  (define txt (screen->string s))
  (check-true (regexp-match? #rx"┌" txt))           ; 有边框
  (check-true (regexp-match? #rx"┬" txt))           ; 跨 panel 的 T
  (check-true (regexp-match? #rx"popup" txt))       ; 浮窗内容
  (displayln "12-panes-tui: ok"))

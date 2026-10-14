#lang racket

;;; core-render/demo.rkt —— 真终端（tui）跑通 core -> 片段 -> put-bytes
;;;
;;; 运行：racket demo.rkt
;;; 会画一帧带颜色的画面，按任意键退出。
;;;
;;; 后端在 backend.rkt：当前 (require tui) 真终端；改 tui/char 即字符图。

(require "backend.rkt" "theme.rkt" "face.rkt" "render.rkt"
         "../core/editor.rkt")

(install-default-theme!)

;;; ---------- 造一个文档 + 视图 ----------

(define text
  (string-join
   (list "(define (add1 x) (+ x 1))"
         ";; 注释：这是一段说明"
         "\"字符串\""
         "(display (add1 41))"
         "(map add1 '(1 2 3))")
   "\n"))

(define b (make-buffer text "demo.rkt"))
(define v (buffer-add-view! b 48 5 #:line-numbers? #t))
(view-resize! v 48 5)

;;; ---------- 上色：fg 分量 + attrs 分量 ----------

(buffer-face-range! b (range-of (point 0 1)  (point 0 7))  (face 'fg-syntax-def    #f '(bold)))
(buffer-face-range! b (range-of (point 1 0)  (point 1 12)) (face 'fg-syntax-comment #f '(italic)))
(buffer-face-range! b (range-of (point 2 0)  (point 2 5))  (face 'fg-syntax-string #f '()))
(buffer-face-range! b (range-of (point 3 1)  (point 3 8))  (face 'fg-syntax-macro  #f '()))
(buffer-face-range! b (range-of (point 4 1)  (point 4 4))  (face 'fg-syntax-binding #f '()))

;; 括号深度：只写 bg 的插件行为 —— 读旧 face、只换 bg、写回（fg 保留）
(for* ([l (in-list '(0 3 4))] [c (in-list '(0 4 8 12))])
  (when (< c (string-length (buffer-line b l)))
    (buffer-face-cell! b l c (face-set-bg (buffer-face-at b l c) 'bg-bracket-1))))

;; 选区 + 多光标：主选区（含主光标）/ 副光标（空选区），三种 overlay 都出现
(view-set-selections! v
  (selections-of (list (selection (point 3 0) (point 3 14))    ; primary：选区 + 主光标
                       (selection (point 4 5) (point 4 5)))    ; 副光标（空选区只有光标）
                 0))

(define entries (list (display-entry v 0 0 0)))

;;; ---------- 画一帧（只用软件光标） ----------

;;; ---------- 画一帧（只用软件光标） ----------

(define (draw!)
  ;; 全量：old 传 #f，patch 会把整屏非空格都给你；前面清屏。
  (define-values (new rends sels) (render-display-patch entries v 48 5 #f))
  (put-bytes (fragment (render-clear) (render-pieces (append rends sels)))))

(with-tui
 (λ ()
   (cursor-hide)                       ; 只用软件光标：直接调 tui 的 cursor-hide
   (draw!)
   (flush!)
   (read-event)                     ; 按任意键退出
   (cursor-show)))

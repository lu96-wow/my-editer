#lang racket

;;; edit4/boot.rkt —— 初始 World（底盘）
;;;
;;; 只负责「造一个能跑的 World」：文档 + 面板 + 主区底盘 + 区域（config/layout.rkt）。
;;; 主区固定为编辑器（弹性）| 状态栏（固定 1 行）；侧栏 / 日志等区域由声明驱动，
;;; 走 content/region.rkt 的 region-show 插入（与运行时 C-b 同一套布局手术）。

(provide boot)

(require "core/world.rkt"
         "env.rkt"
         "content/model.rkt" "content/tree.rkt" "content/region.rkt"
         "view/panel.rkt"
         "app.rkt"
         "config/sidebar.rkt" "config/layout.rkt"
         "layout.rkt")

;; boot：主区(编辑器 / 状态栏) + 声明的区域。
;;   id 0 = 编辑器（弹性），id 1 = 状态栏（固定 1 行）；区域窗格 id 启动时现分配。
;;   无 #:name → 不建初始文档（编辑器窗留空，从文件树打开）。
(define (boot #:env [env (app-environment)]
              #:text [text ""] #:name [name #f] #:path [path #f]
              #:root [root (current-directory)]
              #:screen-width [screen-width 80]
              #:regions [specs (append region-specs (environment-regions env))])
  (define c0 (content-blank))
  (define-values (c1 vid-ed)
    (if name
        (let-values ([(c _did vid) (content-add-doc! c0 text 60 22 name path)])
          (values c vid))
        (values c0 #f)))
  ;; 为 Environment 里所有面板 + 内部 *input* 各建一个文档。
  (define panel-names
    (append (for/list ([p (in-list (environment-panels env))]) (panel-name p))
            (list "*input*")))
  (define-values (c2 panel-vids)
    (for/fold ([c c1] [vids (hash)]) ([nm (in-list panel-names)])
      (cond
        [(hash-has-key? vids nm) (values c vids)]
        [else
         (define-values (c* _did vid) (content-add-panel! c nm 60 6))
         (values c* (hash-set vids nm vid))])))
  (define vid-st (hash-ref panel-vids "*status*"))
  (define sw (sidebar-width screen-width))
  ;; 主区底盘：编辑器（弹性）| 状态栏（固定 1 行）。
  (define main (split 'v 1 (list (child (size 1 #t) (leaf 0 (cons 2 2)))
                                 (child (size 1 #f) (leaf 1 (cons 1 1))))))
  (define c-main (content-bind (if vid-ed (content-bind c2 0 vid-ed) c2) 1 vid-st))
  ;; 区域声明 → region 值（size = auto 用按屏宽算的侧栏宽度）。
  (define regs
    (for/hash ([s (in-list specs)])
      (define sz (if (eq? (caddr s) 'auto) sw (caddr s)))
      (values (car s) (region (cadr s) sz (cadddr s) (list-ref s 4) (list-ref s 5) #f))))
  (define w0 (make-world #:layout main #:focus 0
                         #:content (content-set-regions c-main regs)))
  ;; 启动即显示的区域：用与运行时相同的插入逻辑（insert-side / insert-adjacent）。
  (define w1 (for/fold ([w w0]) ([s (in-list specs)]
                                 #:when (eq? (list-ref s 6) 'shown))
               (region-show w (car s))))
  (refresh-tree! w1 #:root root))

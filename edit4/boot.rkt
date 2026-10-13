#lang racket

;;; edit4/boot.rkt —— 初始 World（底盘）
;;;
;;; 只负责「造一个能跑的 World」：文档 + 面板 + 主区 + 声明 dock（config/layout.rkt）。
;;; 主区只有编辑器；状态栏 / 侧栏 / 日志都是 dock，由 region-mount 插入常驻叶子。

(provide boot)

(require "core/world.rkt"
         "env.rkt"
         "content/model.rkt" "content/tree.rkt" "content/region.rkt"
         "view/panel.rkt"
         "app.rkt"
         "config/sidebar.rkt" "config/layout.rkt"
         "layout.rkt")

;; boot：主区只有编辑器；状态栏 / 侧栏 / 日志都是声明的 dock。
;;   id 0 = 编辑器；dock 窗格 id 启动时按声明顺序现分配。
;;   无 #:name → 不建初始文档（编辑器窗留空，从文件树打开）。
(define (boot #:env [env (app-environment)]
              #:text [text ""] #:name [name #f] #:path [path #f]
              #:root [root (current-directory)]
              #:screen-width [screen-width 80]
              #:screen-height [screen-height 24]
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
  (define-values (c2 _panel-vids)
    (for/fold ([c c1] [vids (hash)]) ([nm (in-list panel-names)])
      (cond
        [(hash-has-key? vids nm) (values c vids)]
        [else
         (define-values (c* _did vid) (content-add-panel! c nm 60 6))
         (values c* (hash-set vids nm vid))])))
  ;; 主区：只有编辑器；状态栏 / 日志 / 侧栏都是 dock（叶子由 region-mount 插入）。
  (define main (leaf 0 (cons 2 2)))
  (define c-main (if vid-ed (content-bind c2 0 vid-ed) c2))
  ;; auto 的 size/min 按 dock 朝向解析：left/right → 宽（屏宽），top/bottom → 高（屏高）。
  (define (auto-dim side)
    (case side
      [(left right) (values (sidebar-width screen-width) sidebar-min-width)]
      [(top bottom) (values (sidebar-height screen-height) sidebar-min-height)]
      [else (values 6 1)]))
  ;; 区域声明 → region 值（size/min = auto 时按 side 解析；leaf 挂载时填）。
  (define regs
    (for/hash ([s (in-list specs)])
      (define-values (asz amn) (auto-dim (cadr s)))
      (define sz (if (eq? (caddr s) 'auto) asz (caddr s)))
      (define mn0 (if (> (length s) 7) (list-ref s 7) 1))
      (define mn (if (eq? mn0 'auto) amn mn0))
      (values (car s) (region (cadr s) sz (cadddr s) (list-ref s 4) (list-ref s 5) #f #f mn))))
  (define w0 (make-world #:layout main #:focus 0
                         #:content (content-set-regions c-main regs)))
  ;; 挂载所有 dock：叶子常驻（隐藏的 size 0 = 折叠）；顺序 = 声明顺序（先插在内层）。
  (define w1
    (for/fold ([w w0]) ([s (in-list specs)])
      (region-mount w (car s) #:shown? (eq? (list-ref s 6) 'shown))))
  (refresh-tree! w1 #:root root))

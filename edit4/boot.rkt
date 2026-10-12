#lang racket

;;; edit4/boot.rkt —— 初始 World（底盘）
;;;
;;; 只负责「造一个能跑的 World」：文档 + 面板 + 布局底盘 + 文件树 + 面板槽。
;;; 面板文档来自 Environment（含插件面板）+ 内部 *input*；布局底盘固定为
;;; 侧栏(root) | 主区(编辑器 / 状态栏)。

(provide boot)

(require "core/world.rkt"
         "env.rkt"
         "content/model.rkt" "content/tree.rkt"
         "view/panel.rkt"
         "app.rkt"
         "layout.rkt")

;; boot：侧栏(树 / 文档管理 互斥) | 主区(编辑器 / 状态栏)。
;;   id 2 = 侧栏槽（固定 28），id 0 = 编辑器（弹性），id 1 = 状态栏（固定 1 行）。
;;   无 #:name → 不建初始文档（编辑器窗留空，从文件树打开）。
(define (boot #:env [env (app-environment)]
              #:text [text ""] #:name [name #f] #:path [path #f]
              #:root [root (current-directory)])
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
  (define vid-tr (hash-ref panel-vids "*tree*"))
  (define vid-st (hash-ref panel-vids "*status*"))
  (define right (split 'v 1 (list (child (size 1 #t) (leaf 0 (cons 2 2)))
                                  (child (size 1 #f) (leaf 1 (cons 1 1))))))
  (define chassis (split 'h 1 (list (child (size 28 #f) (leaf 2 (cons 1 1)))
                                    (child (size 1 #t) right))))
  ;; 侧栏槽（窗口 2 显示 *tree* / *buffers*）；日志槽默认隐藏（C-l 显示，贴主区底部）。
  (define regions
    (hash 'sidebar (region 'left 28 (list "*tree*" "*buffers*") "*tree*" 'root 2)
          'log     (region 'bottom 6 (list "*log*") "*log*" 'main #f)))
  (define c (content-set-regions c2 regions))
  (define c* (content-bind (content-bind (if vid-ed (content-bind c 0 vid-ed) c) 1 vid-st) 2 vid-tr))
  (refresh-tree! (make-world #:layout chassis #:focus 0 #:content c*) #:root root))

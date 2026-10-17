#lang racket

;;; bootstrap/filetree-panel.rkt —— 文件树面板（buffer 支撑）
;;;
;;; 只保留三件事，装配动作全在 bootstrap/panel.rkt：
;;;   install : 建 *filetree* view + region，把 view-id / root 写进 state.filetree
;;;   sync    : 每帧从磁盘生成行 -> panel-sync-buffer!
;;;   lines   : 委托 projection/filetree（纯 / IO 投影）
;;;
;;; IO 读取在 sync / 命令里做，State 只存 view/root/expanded。

(provide install-filetree-panel! sync-filetree-panel! filetree-panel-view)
(provide (all-from-out "../projection/filetree.rkt"))

(require "../model/state.rkt"
         "../model/filetree.rkt"
         "../effects/engine.rkt"
         "../projection/filetree.rkt"
         "panel.rkt")

(define (filetree-panel-view state)
  (filetree-view (state-filetree state)))

(define (install-filetree-panel! engine state region-id root)
  (define root* (filetree-normalize-path root))
  (define-values (s1 vid)
    (panel-install! engine state region-id
                    #:name "*filetree*"
                    #:mode 'filetree
                    #:role 'filetree))
  (state-filetree*
   s1
   (λ (f)
     (define f1 (filetree-set-root f root*))
     (define f2 (if (filetree-expanded? f1 root*)
                    f1
                    (filetree-toggle-expand f1 root*)))
     (filetree-set-view f2 vid))))

(define (sync-filetree-panel! state engine)
  (define vid (filetree-panel-view state))
  (when vid
    (define lines (filetree-lines state))
    (panel-sync-buffer! engine state vid
                        #:texts (map filetree-line-text lines)
                        #:faces (map filetree-line-face lines))))

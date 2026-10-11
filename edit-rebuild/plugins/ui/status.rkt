#lang racket

;;; edit-rebuild/plugins/ui/status.rkt —— 状态行插件（停靠面，1 行）
;;;
;;; 显示活动编辑视图：文档名 + 行:列。每帧由面 content 重生成（内容没变则 #f）。

(require "../../core/extension/api.rkt"
         "../../core/extension/spec.rkt"
         "ids.rkt")

(provide status-spec)

(define (status-text s)
  (define vid (session-edit-vid s))
  (define body
    (cond
      [(not vid) " edit"]
      [else
       (define did (session-view-did s vid))
       (define name (session-document-name s did))
       (format " ~a   ~a:~a" name
               (add1 (session-view-point-line s vid))
               (add1 (session-view-point-column s vid)))]))
  (define pfx (session-prefix s))
  (string-append body (if pfx (format "  [~a]" (prefix-label pfx)) "")))

(define (status-install s)
  (define-values (s1 _did vid)
    (session-add-document s "" (session-width s) 1 #:name "*status*"))
  (define last (box #f))
  (define content
    (lambda (s)
      (define t (status-text s))
      (cond
        [(equal? t (unbox last)) #f]
        [else (set-box! last t) (panel-doc (list (list t #f)))])))
  (session-add-surface
   s1 (dock-surface panel-status vid content #f slot-bottom 'height 1)))

(define status-spec (plugin-spec 'status status-install '()))

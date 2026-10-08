#lang racket

;;; lab-re-rebuild/kernel/documents.rkt —— 文档在主区的放置 / 显示（纯 workspace 操作）。
;;;
;;; 只碰 editor + frame + session；不认识文件 / 路径 / 磁盘。
;;; 文件 I/O 由特性（builtin/document.rkt）负责。

(require "editor-api.rkt" "session.rkt" "runtime.rkt" "focus.rkt" "frame.rkt" "workspace.rkt")

(provide place-view show-document main-view? sticky-edit)

(define (main-view? s vid)
  (and vid (frame-contains? (workspace-main (session-workspace s)) vid)))

;; focus 落在主区叶时，把 edit-vid 一起更新（粘性规则）。
(define (sticky-edit s)
  (define fv (session-focus-vid s))
  (if (main-view? s fv) (struct-copy session s [edit-vid fv]) s))

;; 把 vid 放进活动主区叶：'replace 或 (list 'split dir)。
(define (place-view fr active vid placement)
  (cond
    [(frame-contains? fr vid) fr]
    [(not (frame-root fr)) (frame-set-root fr (leaf vid 'edit))]
    [(and active (frame-contains? fr active))
     (if (and (pair? placement) (eq? (car placement) 'split))
         (frame-split fr active (cadr placement) vid)
         (frame-replace fr active (leaf vid 'edit)))]
    [else (frame-set-root fr (leaf vid 'edit))]))

;; 显示某个 did 的视图（没有就建一个），放进主区。→ (values ctx did)
(define (show-document ctx did placement focus?)
  (define s (ctx-session ctx))
  (define ed (session-editor s))
  (define vids (editor-document-view-list ed did))
  (define-values (ctx1 vid)
    (cond
      [(pair? vids) (values ctx (car vids))]
      [else
       (define-values (ed2 vid)
         (editor-add-view ed did (session-width s) (max 1 (sub1 (session-height s)))
                          #:line-numbers? #t))
       (values (ctx-with-session ctx (struct-copy session s [editor ed2])) vid)]))
  (define s1 (ctx-session ctx1))
  (define ws (session-workspace s1))
  (define fr (place-view (workspace-main ws) (session-edit-vid s1) vid placement))
  (define s2 (struct-copy session s1 [workspace (struct-copy workspace ws [main fr])]))
  (define s3 (if focus?
                 (sticky-edit (struct-copy session s2 [focus (focus-set (session-focus s2) vid)]))
                 s2))
  (values (ctx-with-session ctx1 s3) did))

#lang racket

;;; edit-tui/host/bilingual.rkt —— 双语 pair 的宿主生命周期
;;;
;;; 插件只发 action；这里负责：
;;;   · 创建 derived mirror
;;;   · 挂到源 view 所在 panel
;;;   · bind / unbind plugin-state
;;;   · 把镜像反译 action 写成源 user doc 的整行替换
;;;
;;; 不在这里做翻译逻辑；translator / pair / state 都在插件内。

(require "../editor/host-api.rkt"
         "../plugins/bilingual/api.rkt"
         "layout.rkt"
         "derived-buffer.rkt")

(provide bilingual-open-pair!
         bilingual-close-pair!
         bilingual-close-pair-for-source!
         bilingual-focus-mirror!
         bilingual-replace-source-lines!)

(define (plugin-state state)
  (state-plugin-state state 'bilingual))

(define (set-plugin-state state ps)
  (state-set-plugin-state state 'bilingual ps))

(define (flash state text)
  (values (state-with-flash state text) '()))

(define (source-view-id state source-doc-id)
  (define r (state-resource-for-doc state source-doc-id))
  (and r
       (pair? (resource-views r))
       (car (resource-views r))))

;; 重新挂 mirror 需要 source view 真正在 layout 里；resource-views 里可能还有
;; 被 C-w d detach 的 view。
(define (attached-source-view-id state source-doc-id)
  (define r (state-resource-for-doc state source-doc-id))
  (and r
       (for/first ([vid (in-list (resource-views r))]
                   #:when (editor-view-panel-id state vid))
         vid)))

(define (focus-view! ed state vid)
  (define-values (state* actions attached?)
    (editor-focus-view-if-attached! ed state vid))
  (cond
    [attached? (values state* actions)]
    [else (flash state* "bilingual: mirror view is detached")]))

(define (attach-mirror-view! state source-vid mirror-vid)
  (let-values ([(s ok?)
                (editor-attach-view-in-new-split!
                 state source-vid mirror-vid 'right)])
    (if ok?
        (values s #t)
        (editor-attach-view-as-tab! state source-vid mirror-vid))))

;; source / mirror 是否同 panel，决定 pair-border 还是两侧边框。
(define (apply-pair-faces state source-vid mirror-vid)
  (define source-pid (editor-view-panel-id state source-vid))
  (define mirror-pid (editor-view-panel-id state mirror-vid))
  (cond
    [(and source-pid mirror-pid (equal? source-pid mirror-pid))
     (editor-set-panel-face! state source-pid 'bilingual-pair-border)]
    [else
     (define s1
       (if source-pid
           (editor-set-panel-face! state source-pid 'bilingual-source-border)
           state))
     (if mirror-pid
         (editor-set-panel-face! s1 mirror-pid 'bilingual-mirror-border)
         s1)]))

;; C-w d 只 detach mirror panel；M-l / focus 时把已有 mirror 重新挂回去。
(define (bilingual-focus-mirror! ed state mirror-vid)
  (cond
    [(editor-view-panel-id state mirror-vid)
     (focus-view! ed state mirror-vid)]
    [else
     (define mirror-did (editor-view-doc-id ed mirror-vid))
     (define p (and mirror-did
                    (bilingual-pair-for-mirror (plugin-state state) mirror-did)))
     (cond
       [(not p)
        (flash state "bilingual: mirror view is detached")]
       [else
        (define source-vid
          (attached-source-view-id state (pair-source-doc-id p)))
        (cond
          [(not source-vid)
           (flash state
                  "bilingual: source view is detached; place source first")]
          [else
           (define-values (state1 attached?)
             (attach-mirror-view! state source-vid mirror-vid))
           (cond
             [(not attached?)
              (flash state1 "bilingual: cannot reattach mirror view")]
             [else
              (define state2 (apply-pair-faces state1 source-vid mirror-vid))
              (define-values (state3 actions)
                (focus-view! ed state2 mirror-vid))
              (values (state-with-flash state3
                                       "bilingual: mirror reattached")
                      actions)])])])]))

(define (bilingual-open-pair! ed state source-doc-id translator-id)
  (define ps (plugin-state state))
  (define r (state-resource-for-doc state source-doc-id))
  (cond
    [(not (bilingual-state? ps))
     (flash state "bilingual: plugin state missing")]
    [(not r)
     (flash state "bilingual: source is not an open resource")]
    [(not (eq? (editor-doc-kind ed source-doc-id) 'user))
     (flash state "bilingual: source is not a user document")]
    [else
     (define existing (bilingual-pair-for-source ps source-doc-id))
     (cond
       [existing
        (bilingual-focus-mirror! ed state (pair-mirror-view-id existing))]
       [else
        (define source-vid (source-view-id state source-doc-id))
        (cond
          [(not source-vid)
           (flash state "bilingual: source has no view")]
          [else
           (define tr-id
             (or translator-id (bilingual-default-translator-id ps)))
           (define-values (state1 did vid)
             (create-derived-buffer! ed state
                                     #:name (format "~a [双语]"
                                                    (resource-name r))
                                     #:owner 'bilingual
                                     #:source-doc-id source-doc-id))
           (define-values (state2 attached?)
             (attach-mirror-view! state1 source-vid vid))
           (cond
             [(not attached?)
              (define-values (state3 _actions)
                (remove-derived-buffer! ed state2 did))
              (flash state3 "bilingual: cannot attach mirror view")]
             [else
              (define ps2 (plugin-state state2))
              (define-values (_state3 ps3)
                (bilingual-bind! state2 ps2 source-doc-id did vid tr-id))
              (define state4 (set-plugin-state state2 ps3))
              ;; 面板颜色反映 pair 关联：source / mirror / 同一 panel tab fallback。
              (define state5 (apply-pair-faces state4 source-vid vid))
              (values (state-with-flash
                       state5
                       (format "bilingual: opened ~a" (resource-name r)))
                      '())])])])]))

(define (bilingual-close-pair! ed state source-doc-id
                               #:flash? [flash? #t]
                               #:focus-source? [focus-source? #t])
  (define ps (plugin-state state))
  (define p (bilingual-pair-for-source ps source-doc-id))
  (cond
    [(not p)
     (if flash?
         (flash state "bilingual: no pair for this buffer")
         (values state '()))]
    [else
     (define-values (state1 _actions)
       (remove-derived-buffer! ed state (pair-mirror-doc-id p)))
     (define ps1 (plugin-state state1))
     (define-values (_state2 ps2)
       (bilingual-unbind! state1 ps1 source-doc-id))
     (define state3 (set-plugin-state state1 ps2))
     (define source-vid (source-view-id state3 source-doc-id))
     ;; 取消关联后，源 panel 恢复普通边框；源已关闭时没有可恢复的 view。
     (define state4
       (if source-vid
           (let ([pid (editor-view-panel-id state3 source-vid)])
             (if pid
                 (editor-set-panel-face! state3 pid 'window-border)
                 state3))
           state3))
     ;; 从 mirror 上 M-l 关闭时，把焦点还给 source。否则焦点可能落到
     ;; sidebar / filetree，下一次 M-l 不会按 source buffer 的语义重新打开。
     (define-values (state5 actions5)
       (cond
         [(and focus-source? source-vid)
          (let-values ([(s acts ok?)
                        (editor-focus-view-if-attached! ed state4 source-vid)])
            (if ok?
                (values s acts)
                (values state4 '())))]
         [else (values state4 '())]))
     (values (if flash?
                 (state-with-flash state5 "bilingual: closed")
                 state5)
             actions5)]))

(define (bilingual-close-pair-for-source! ed state source-doc-id)
  (bilingual-close-pair! ed state source-doc-id
                         #:flash? #f
                         #:focus-source? #f))

(define (bilingual-replace-source-lines! ed state source-doc-id
                                         start-line end-line lines)
  (define vid (source-view-id state source-doc-id))
  (cond
    [(not vid)
     (flash state "bilingual: source no longer has a view")]
    [else
     (editor-replace-lines! ed state vid start-line end-line lines)]))

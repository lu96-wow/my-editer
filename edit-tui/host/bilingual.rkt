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

(define (focus-view! ed state vid)
  (define-values (state* actions attached?)
    (editor-focus-view-if-attached! ed state vid))
  (cond
    [attached? (values state* actions)]
    [else (flash state* "bilingual: mirror view is detached")]))

(define (bilingual-focus-mirror! ed state mirror-vid)
  (focus-view! ed state mirror-vid))

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
             (editor-attach-view-as-tab! state1 source-vid vid))
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
              (values (state-with-flash
                       state4
                       (format "bilingual: opened ~a" (resource-name r)))
                      '())])])])]))

(define (bilingual-close-pair! ed state source-doc-id
                               #:flash? [flash? #t])
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
     (values (if flash?
                 (state-with-flash state3 "bilingual: closed")
                 state3)
             '())]))

(define (bilingual-close-pair-for-source! ed state source-doc-id)
  (bilingual-close-pair! ed state source-doc-id #:flash? #f))

(define (bilingual-replace-source-lines! ed state source-doc-id
                                         start-line end-line lines)
  (define vid (source-view-id state source-doc-id))
  (cond
    [(not vid)
     (flash state "bilingual: source no longer has a view")]
    [else
     (editor-replace-lines! ed state vid start-line end-line lines)]))

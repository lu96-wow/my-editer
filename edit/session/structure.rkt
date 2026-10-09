#lang racket

;;; edit/session/structure.rkt —— 视图 / 布局结构手术
;;;
;;; 显示 / 分屏 / 关闭 / 显隐 / 尺寸。
;;; 编辑区手术全部在 **editor 子树**上做（session-set-editor），骨架 frame 不动；
;;; 面板区域的尺寸在骨架里，见 session/bottom.rkt 的 session-fit-panel!。
;;; 都走 core.rkt 的内核适配，不直接碰 core/editor。

(require "value.rkt"
         "doc.rkt"
         "core.rkt"
         "focus.rkt"
         "plugin.rkt"
         "../core/area.rkt"
         "../core/layout.rkt"
         "../core/focus.rkt")

(provide
 session-show-view session-split-view session-place-view
 session-close-view session-close-document
 session-hide-view session-hide-focused session-split-focused
 session-toggle-slot session-resize-view)

;; 把 vid 显示到编辑区并聚焦。
(define (session-show-view s vid)
  (define s1
    (cond
      [(layout-contains? (session-editor s) vid) s]
      [else
       ;; 隐藏中的视图：放回编辑区（有编辑视图则分屏，否则填 blank）
       (define base (session-edit-vid s))
       (if (and base (not (eqv? base vid)) (layout-contains? (session-editor s) base))
           (session-place-view s base 'lr vid)
           (session-place-view s #f 'lr vid))]))
  (session-set-focus s1 (focus-set (session-focus s1) vid)))

;; 在 vid 旁按 axis 分屏出一个新视图（同文档，继承行号设置）；焦点移到新视图。
(define (session-split-view s vid axis)
  (define did (session-view-did s vid))
  (define w (max 5 (session-view-width s vid)))
  (define h (max 3 (session-view-height s vid)))
  (define ln? (session-view-line-numbers? s vid))
  (define-values (s1 nvid) (session-add-view s did w h #:line-numbers? ln?))
  (define s2 (session-set-editor s1 (layout-split (session-editor s1) vid axis nvid)))
  (session-show-view s2 nvid))

;; 分裂焦点编辑器（面板不分裂）。axis : 'lr（垂直分隔/左右）| 'tb（水平分隔/上下）。
(define (session-split-focused s axis)
  (define vid (session-focus-vid s))
  (if (and vid (not (session-dock-vid? s vid)))
      (session-split-view s vid axis)
      s))

;; 把已在 editor 里的视图 nvid 放到 vid 旁（分屏）；
;; 没有基准视图（编辑区为空）则把第一个 blank 占位换成新视图。
(define (session-place-view s vid axis nvid)
  (define et (session-editor s))
  (session-set-editor s
    (cond
      [(and vid (layout-contains? et vid)) (layout-split et vid axis nvid)]
      [else (layout-replace-first-blank et (leaf nvid))])))

;; 从编辑区子树移除若干视图；若编辑区就空了，保留一个 blank 占位
;; （否则 split 会塌陷，底部区会占满整个编辑区）。→ 新 editor 子树
(define (session-drop-editor-views s vids)
  (define remain (for/list ([v (in-list (session-view-id-list s))]
                            #:unless (or (memv v vids) (session-dock-vid? s v))) v))
  (define et (session-editor s))
  (cond
    [(null? vids) et]
    [(pair? remain)
     (for/fold ([t et]) ([v (in-list vids)]) (layout-remove t v))]
    [else
     (for/fold ([t (layout-replace et (first vids) (blank))])
               ([v (in-list (rest vids))])
       (layout-remove t v))]))

;; 关视图后：若粘性 edit-vid 已不在，重置为第一个编辑器视图（或 #f）。
(define (session-fix-edit-vid s)
  (define ev (session-edit-vid s))
  (cond
    [(and ev (memv ev (session-view-id-list s)) (not (session-dock-vid? s ev))) s]
    [else
     (define rest (for/list ([v (in-list (session-view-id-list s))]
                             #:unless (session-dock-vid? s v)) v))
     (struct-copy session s [edit-vid (and (pair? rest) (first rest))])]))

;; 关一个编辑视图（状态窗口不受影响）。
(define (session-close-view s vid)
  (cond
    [(session-dock-vid? s vid) s]
    [else
     (define did (session-view-did s vid))
     (define remaining (remove vid (session-document-view-list s did)))
     (cond
       [(null? remaining) (session-close-document s did)]
       [else
        (define s0 (session-ed-close-view s vid))
        (define s* (session-set-editor
                    (struct-copy session s0
                      [presentations (hash-remove (session-presentations s) vid)])
                    (session-drop-editor-views s (list vid))))
        (define s** (if (eqv? vid (session-focus-vid s*))
                        (session-show-view s* (first remaining))
                        s*))
        (session-fix-edit-vid s**)])]))

;; 关一个文档（连带其所有视图）；不关状态窗口。同时清 doc-state（path + 脏）。
(define (session-close-document s did)
  (define vids (session-document-view-list s did))
  (cond
    [(for/or ([v (in-list vids)]) (session-dock-vid? s v)) s]
    [else
     (define pres* (for/fold ([h (session-presentations s)]) ([v (in-list vids)]) (hash-remove h v)))
     (define s0 (session-ed-close-document s did))
     (define s* (session-doc-plugin-forget
                 (session-clear-doc
                  (session-set-editor
                   (struct-copy session s0 [presentations pres*])
                   (session-drop-editor-views s vids))
                  did)
                 did))
     (define fv (session-focus-vid s*))
     (define s** (cond
                   [(and fv (memv fv vids))
                    (define rest (for/list ([v (in-list (session-view-id-list s*))]
                                            #:unless (session-dock-vid? s* v)) v))
                    (session-set-focus s* (focus-set (session-focus s*) (and (pair? rest) (first rest))))]
                   [else s*]))
     (session-fix-edit-vid s**)]))

;; 隐藏视图：从编辑区移除（**不关 view、不关 document**）；焦点 / 活动视图移到仍在显示的编辑器视图。
(define (session-hide-view s vid)
  (define s1 (session-set-editor s (session-drop-editor-views s (list vid))))
  (define placed (for/list ([v (in-list (session-view-id-list s1))]
                            #:unless (session-dock-vid? s1 v)
                            #:when (layout-contains? (session-editor s1) v)) v))
  (define target (and (pair? placed) (first placed)))
  (define s2 (if (eqv? vid (session-focus-vid s1))
                 (session-set-focus s1 (focus-set (session-focus s1) target))
                 s1))
  (struct-copy session s2
    [edit-vid (if (and (session-edit-vid s2)
                       (layout-contains? (session-editor s2) (session-edit-vid s2)))
                  (session-edit-vid s2)
                  target)]))

;; 隐藏焦点编辑器视图（面板不动）。
(define (session-hide-focused s)
  (define vid (session-focus-vid s))
  (if (and vid (not (session-dock-vid? s vid)))
      (session-hide-view s vid)
      s))

;; 切换 bindings 里某个洞（面板）的显隐。
(define (session-toggle-slot s slot)
  (define node (hash-ref (session-bindings s) slot #f))
  (define vids (layout-vids node))
  (cond
    [(null? vids) s]
    [else
     (define any-visible? (for/or ([v (in-list vids)]) (session-visible? s v)))
     (define s1 (for/fold ([s s]) ([v (in-list vids)]) (session-set-visible s v #f)))
     (if any-visible? s1 (session-set-visible s1 (first vids) #t))]))

;; 改焦点编辑器视图尺寸（调整编辑区里最近的同向 split）。axis : 'width | 'height
(define (session-resize-view s axis delta)
  (define vid (session-focus-vid s))
  (cond
    [(not vid) s]
    [(layout-contains? (session-editor s) vid)
     (session-set-editor s
       (layout-resize (session-editor s) vid axis delta
                      (area 0 0 (session-width s) (session-height s))))]
    [else s]))

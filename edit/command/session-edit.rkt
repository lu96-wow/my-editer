#lang racket

;;; edit/command/session-edit.rkt —— 结构手术 + 操作原语
;;;
;;; 结构手术：视图的显示 / 分屏 / 关闭（改真身 + layout）。
;;; 操作原语：命令层需要的那几个（焦点 / 滚动 / 导航 / 尺寸 / 选区 / 剪贴板 / 编辑）。
;;; 都走 session-core 的内核适配，不直接碰 core/editor。

(require "session-value.rkt"
         "session-core.rkt"
         "session-focus.rkt"
         "../core/area.rkt"
         "../core/layout.rkt"
         "../core/focus.rkt")

(provide
 ;; 结构手术
 session-show-view session-split-view session-place-view
 session-close-view session-close-document
 ;; 操作原语
 session-focus-move session-scroll session-toggle-slot
 session-resize session-quit session-nav session-resize-view
 session-select-all session-copy session-cut session-paste
 session-insert session-delete session-backspace
 session-undo session-redo)

;;; ---------- 结构手术 ----------

(define (session-show-view s vid)
  (session-set-focus s (focus-set (session-focus s) vid)))

;; 在 vid 旁按 axis 分屏出一个新视图（同文档）；焦点移到新视图。
(define (session-split-view s vid axis)
  (define did (session-view-did s vid))
  (define w (max 5 (session-view-width s vid)))
  (define h (max 3 (session-view-height s vid)))
  (define-values (s1 nvid) (session-add-view s did w h))
  (define s2 (struct-copy session s1
               [layout (layout-split (session-layout s1) vid axis nvid)]))
  (session-show-view s2 nvid))

;; 把已在 editor 里的视图 nvid 放到 vid 旁（分屏）；layout 为空则直接作为根。
(define (session-place-view s vid axis nvid)
  (cond
    [(not (session-layout s)) (struct-copy session s [layout (leaf nvid)])]
    [(layout-contains? (session-layout s) vid)
     (struct-copy session s [layout (layout-split (session-layout s) vid axis nvid)])]
    [else s]))

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
        (define s* (struct-copy session s0
                     [layout (layout-remove (session-layout s) vid)]
                     [presentations (hash-remove (session-presentations s) vid)]))
        (if (eqv? vid (session-focus-vid s*))
            (session-show-view s* (first remaining))
            s*)])]))

;; 关一个文档（连带其所有视图）；不关状态窗口。同时清 doc-state（path + 脏）。
(define (session-close-document s did)
  (define vids (session-document-view-list s did))
  (cond
    [(for/or ([v (in-list vids)]) (session-dock-vid? s v)) s]
    [else
     (define layout* (for/fold ([l (session-layout s)]) ([v (in-list vids)]) (layout-remove l v)))
     (define pres* (for/fold ([h (session-presentations s)]) ([v (in-list vids)]) (hash-remove h v)))
     (define s0 (session-ed-close-document s did))
     (define s* (session-clear-doc
                 (struct-copy session s0 [layout layout*] [presentations pres*])
                 did))
     (define fv (session-focus-vid s*))
     (cond
       [(and fv (memv fv vids))
        (define rest (for/list ([v (in-list (session-view-id-list s*))]
                                #:unless (session-dock-vid? s* v)) v))
        (session-set-focus s* (focus-set (session-focus s*) (and (pair? rest) (first rest))))]
       [else s*])]))

;;; ---------- 操作原语 ----------

(define (with-focus-vid s proc)
  (define vid (session-focus-vid s))
  (when vid (proc vid))
  s)

(define (session-focus-move s dir)
  (session-set-focus s (focus-move (session-views s) (session-focus s) dir)))

(define (session-scroll s n)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (session-ed-scroll! s vid n))))

(define (session-nav s dir extend?)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (session-ed-nav! s vid dir extend?))))

(define (session-toggle-slot s slot)
  (define node (hash-ref (session-bindings s) slot #f))
  (define vids (layout-vids node))
  (cond
    [(null? vids) s]
    [else
     (define any-visible? (for/or ([v (in-list vids)])
                            (presentation-visible? (session-presentation s v))))
     (define s1 (for/fold ([s s]) ([v (in-list vids)]) (session-set-visible s v #f)))
     (if any-visible? s1 (session-set-visible s1 (first vids) #t))]))

(define (session-resize s w h) (struct-copy session s [width w] [height h]))
(define (session-quit s) (struct-copy session s [quit? #t]))

;; 改焦点视图尺寸：调整 layout 里最近的同向 split 那一项（axis : 'width | 'height）。
(define (session-resize-view s axis delta)
  (define vid (session-focus-vid s))
  (cond
    [(not vid) s]
    [else
     (struct-copy session s
       [layout (layout-resize (session-layout s) vid axis delta
                              (area 0 0 (session-width s) (session-height s)))])]))

;; 选区 / 剪贴板（转发 core）
(define (session-select-all s)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (session-ed-select-all! s vid))))
(define (session-copy s)
  (with-focus-vid s (lambda (vid) (session-ed-copy! s vid))))
(define (session-cut s)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (session-ed-cut! s vid))))
(define (session-paste s)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (session-ed-paste! s vid))))

(define (session-insert s text)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (session-ed-insert! s vid text))))
(define (session-delete s)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (session-ed-delete! s vid))))
(define (session-backspace s)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (session-ed-backspace! s vid))))
(define (session-undo s)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (session-ed-undo! s vid))))
(define (session-redo s)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (session-ed-redo! s vid))))

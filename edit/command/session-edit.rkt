#lang racket

;;; edit/command/session-edit.rkt —— 结构手术 + 操作原语
;;;
;;; 结构手术：视图的显示 / 分屏 / 关闭（改真身 + layout）。
;;; 操作原语：命令层需要的那几个（焦点 / 滚动 / 导航 / 尺寸 / 选区 / 剪贴板 / 编辑）。
;;; 都是纯转换 session -> session；内嵌 core editor 骨架不可变、内部 box 可变。

(require "session-value.rkt"
         "session-core.rkt"
         "session-window.rkt"
         "../../core/editor.rkt"
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
  (define ed (session-ed s))
  (define did (editor-view-document-id ed vid))
  (define w (max 5 (editor-view-width ed vid)))
  (define h (max 3 (editor-view-height ed vid)))
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
     (define ed (session-ed s))
     (define did (editor-view-document-id ed vid))
     (define remaining (remove vid (editor-document-view-list ed did)))
     (cond
       [(null? remaining) (session-close-document s did)]
       [else
        (define ed* (editor-close-view ed vid))
        (define s* (struct-copy session s
                     [ed ed*]
                     [layout (layout-remove (session-layout s) vid)]
                     [presentations (hash-remove (session-presentations s) vid)]))
        (if (eqv? vid (session-focus-vid s*))
            (session-show-view s* (first remaining))
            s*)])]))

;; 关一个文档（连带其所有视图）；不关状态窗口。同时清 file-map。
(define (session-close-document s did)
  (define ed (session-ed s))
  (define vids (editor-document-view-list ed did))
  (cond
    [(for/or ([v (in-list vids)]) (session-dock-vid? s v)) s]
    [else
     (define ed* (editor-close-document ed did))
     (define layout* (for/fold ([l (session-layout s)]) ([v (in-list vids)]) (layout-remove l v)))
     (define pres* (for/fold ([h (session-presentations s)]) ([v (in-list vids)]) (hash-remove h v)))
     (define s* (session-clear-doc
                 (struct-copy session s [ed ed*] [layout layout*] [presentations pres*])
                 did))
     (define fv (session-focus-vid s*))
     (cond
       [(and fv (memv fv vids))
        (define rest (for/list ([v (in-list (editor-view-id-list ed*))]
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
  (with-focus-vid s (lambda (vid) (editor-view-scroll! (session-ed s) vid n))))

(define (session-nav s dir extend?)
  (sync-layout! s)
  (define ed (session-ed s))
  (with-focus-vid s
    (lambda (vid)
      (case dir
        [(left)  (editor-view-left! ed vid extend?)]
        [(right) (editor-view-right! ed vid extend?)]
        [(up)    (editor-view-up! ed vid extend?)]
        [(down)  (editor-view-down! ed vid extend?)]
        [(home)  (editor-view-home! ed vid extend?)]
        [(end)   (editor-view-end! ed vid extend?)]
        [else (error 'session-nav "未知方向: ~a（left/right/up/down/home/end）" dir)]))))

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
  (with-focus-vid s (lambda (vid) (editor-view-select-all! (session-ed s) vid))))
(define (session-copy s)
  (with-focus-vid s (lambda (vid) (editor-view-copy! (session-ed s) vid))))
(define (session-cut s)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (editor-view-cut! (session-ed s) vid))))
(define (session-paste s)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (editor-view-paste! (session-ed s) vid))))

(define (session-insert s text)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (editor-view-insert! (session-ed s) vid text))))
(define (session-delete s)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (editor-view-delete! (session-ed s) vid))))
(define (session-backspace s)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (editor-view-backspace! (session-ed s) vid))))
(define (session-undo s)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (editor-view-undo! (session-ed s) vid))))
(define (session-redo s)
  (sync-layout! s)
  (with-focus-vid s (lambda (vid) (editor-view-redo! (session-ed s) vid))))

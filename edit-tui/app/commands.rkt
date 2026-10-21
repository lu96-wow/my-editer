#lang racket

;;; edit-tui-rebuild/app/commands.rkt —— 应用级命令（layout / focus / save / quit）
;;;
;;; 只定义命令，不定义键位；键位在 config/keymap/。
;;; 所有命令都是 (state -> (values state actions))，不碰 engine / IO。

(require "../core/skeleton.rkt"
         "state.rkt")

(provide split-command
         close-panel-command
         toggle-filetree-command
         focus-command
         save-command
         quit-command)

(define (split-command dir)
  (λ (state)
    (define layout (app-state-layout state))
    (define pid (app-state-focus-panel-id state))
    (define nid (app-state-next-panel-id state))
    (define-values (layout* ok?)
      (layout-split layout pid dir nid
                    #:config (app-state-layout-config state)))
    (if ok?
        (values (struct-copy app-state state
                             [layout layout*]
                             [next-panel-id (add1 nid)])
                '())
        (values (app-state-with-flash state "split failed") '()))))

;; close-panel：只处理 editor panel，不关闭 resource / buffer / view。
;; 还有其他 editor -> 删除当前 panel；
;; 已是最后一个 editor -> 只清空它的 views，保留 slot。
(define (other-editor-panel? layout pid)
  (for/or ([id (in-list (layout-visible-panel-ids layout))])
    (and (not (equal? id pid))
         (eq? (panel-kind (layout-panel layout id)) 'editor)
         id)))

(define (close-panel-command state)
  (define pid (app-state-focus-panel-id state))
  (define p (app-state-panel state pid))
  (define layout (app-state-layout state))
  (cond
    [(not p)
     (values (app-state-with-flash state "close: no focused panel") '())]
    [(not (eq? (panel-kind p) 'editor))
     (values (app-state-with-flash state "close: focus is not an editor panel") '())]
    [else
     (define-values (layout* ok?)
       (if (other-editor-panel? layout pid)
           (layout-panel-remove layout pid
                                #:config (app-state-layout-config state))
           (layout-panel-clear-content layout pid)))
     (if ok?
         (values (struct-copy app-state state [layout layout*]) '())
         (values (app-state-with-flash state "close editor panel failed") '()))]))

(define (toggle-filetree-command state)
  (define layout (app-state-layout state))
  (define area (app-state-area state))
  (define visible? (layout-panel-visible? layout 'filetree))
  (define-values (layout* ok?)
    (if visible?
        (layout-panel-hide layout area 'filetree
                           #:config (app-state-layout-config state))
        (layout-panel-show layout area 'filetree)))
  (if ok?
      (values (struct-copy app-state state [layout layout*]) '())
      (values (app-state-with-flash state "toggle filetree failed") '())))

(define (focus-command dir)
  (λ (state)
    (define layout (app-state-layout state))
    (define to (layout-focus-neighbor layout (app-state-area state)
                                      (app-state-layout-config state)
                                      (app-state-focus-panel-id state) dir))
    (if to
        (values (app-state-set-focus-panel state to) '())
        (values (app-state-with-flash state "no focus neighbor") '()))))

(define (save-command state)
  (define rid (app-state-focus-resource state))
  (cond
    [(not rid) (values (app-state-with-flash state "save: no resource") '())]
    [else
     (define-values (store* actions)
       (resource-save (app-state-resources state) rid))
     (values (struct-copy app-state state [resources store*]) actions)]))

(define (quit-command state)
  (define-values (store* actions)
    (resource-request-quit (app-state-resources state)))
  (values (struct-copy app-state state [resources store*]) actions))

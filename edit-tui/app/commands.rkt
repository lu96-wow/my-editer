#lang racket

;;; edit-tui-rebuild/app/commands.rkt —— 应用级命令（split / focus / save / quit）
;;;
;;; 只定义命令，不定义键位；键位在 config/keymap/。
;;; 所有命令都是 (state -> (values state actions))，不碰 engine / IO。

(require "../core/skeleton.rkt"
         "state.rkt")

(provide split-command
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
        (values (app-state-refresh-focus-resource
                 (struct-copy app-state state
                              [layout layout*]
                              [next-panel-id (add1 nid)]))
                '())
        (values (app-state-with-message state "split failed") '()))))

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
      ;; 隐藏可能导致焦点回退：按新 layout 的焦点重算 focus-resource
      (values (app-state-refresh-focus-resource
               (struct-copy app-state state [layout layout*]))
              '())
      (values (app-state-with-message state "toggle filetree failed") '())))

(define (focus-command dir)
  (λ (state)
    (define layout (app-state-layout state))
    (define to (layout-focus-neighbor layout (app-state-area state)
                                      (app-state-layout-config state)
                                      (app-state-focus-panel-id state) dir))
    (if to
        (values (app-state-set-focus-panel state to) '())
        (values (app-state-with-message state "no focus neighbor") '()))))

(define (save-command state)
  (define rid (app-state-focus-resource state))
  (cond
    [(not rid) (values (app-state-with-message state "save: no resource") '())]
    [else
     (define-values (store* actions)
       (resource-save (app-state-resources state) rid))
     (values (struct-copy app-state state [resources store*]) actions)]))

(define (quit-command state)
  (define-values (store* actions)
    (resource-request-quit (app-state-resources state)))
  (values (struct-copy app-state state [resources store*]) actions))

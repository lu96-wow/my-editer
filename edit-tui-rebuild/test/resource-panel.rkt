#lang racket

;;; edit-tui-rebuild/test/resource-panel.rkt —— 资源列表面板
;;;
;;; 覆盖：document/view 颜色、折叠、面板内创建 view/document、显式 placement。

(require rackunit
         racket/async-channel
         "../../edit-tui/command/key.rkt"
         "../../edit-tui/command/mouse.rkt"
         (prefix-in app: "../base/event.rkt")
         "../base/id.rkt"
         "../base/transition.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../model/resources.rkt"
         "../model/chrome.rkt"
         "../effects/engine.rkt"
         "../bootstrap/resource-panel.rkt"
         "../bootstrap/defaults.rkt"
         "../runtime/run.rkt")

(define (feed eng s . evs)
  (transition-state (process-events default-env eng (make-async-channel) s evs)))
(define (plain c) (app:key-event (key c)))
(define (ctrl c)  (app:key-event (key c 'ctrl)))
(define (meta c)  (app:key-event (key c 'alt)))

(define d1 (doc-id 1))
(define v1 (view-id 1))
(define erid (region-id 1))
(define rrid (region-id 2))
(define engine (make-engine))
(void (engine-create-doc! engine d1 "main.rkt" "hello\n"))
(void (engine-create-view! engine v1 d1))
(define baseline (engine-view-doc-version (make-engine-view engine) d1))
(define ws0
  (let* ([ws (workspace-empty)]
         [ws (workspace-add-doc ws d1 (make-doc-meta "main.rkt" #:saved-version baseline))]
         [ws (workspace-add-view ws v1 (view-meta d1 (hash)))]
         [ws (workspace-add-region ws erid (region erid (list (view-member v1)) v1 'editor))])
    ws))
(define s0 (make-state #:workspace ws0 #:ids (make-id-counter 2 2 3 1)))
(define s1 (install-resource-panel! engine s0 rrid))
(define rvid (resources-view (state-resources s1)))
(define lay (make-split 'lr
                        (list (make-leaf rrid (flex 1))
                              (make-leaf erid (flex 2)))
                        (flex 1)))
(define state
  (state-set-focus
   (state-set-workspace s1
                        (struct-copy workspace (state-workspace s1) [layout lay]))
   rvid))

;;; ════════════════ 行 / 颜色 ════════════════

(define lines0 (resource-lines state))
(check-equal? (length lines0) 2)
(check-eq? (resource-line-kind (car lines0)) 'doc)
(check-true (string-contains? (resource-line-text (car lines0)) "main.rkt"))
(check-eq? (resource-line-face (car lines0)) 'resource-document)
(check-eq? (resource-line-kind (cadr lines0)) 'view)
(check-true (string-contains? (resource-line-text (cadr lines0)) "region"))

;;; ════════════════ 折叠 ════════════════

(define s2 (feed engine state (app:key-event (key 'enter))))
(check-true (resources-collapsed? (state-resources s2) d1))
(check-equal? (length (resource-lines s2)) 1)
(define s3 (feed engine s2 (app:key-event (key 'enter))))
(check-false (resources-collapsed? (state-resources s3) d1))
(check-equal? (length (resource-lines s3)) 2)

;;; ════════════════ 面板内创建 detached view ════════════════

(sync-resource-panel! s3 engine)
(define s4 (feed engine s3 (plain #\v)))       ; 光标在 doc 行
(sync-resource-panel! s4 engine)
(check-equal? (hash-count (workspace-views (state-workspace s4))) 3) ; v1 + resource + new
(define v2 (view-id 3))
(check-false (workspace-view-attached? (state-workspace s4) v2))
(check-true (for/or ([v (in-list (workspace-detached-views (state-workspace s4)))])
              (equal? v v2)))

;;; ════════════════ placement：r -> 选 panel -> C-x C-p ════════════════

;; 选中 v2 行（doc0, v1 1, v2 2）
(define s5 (feed engine s4 (app:key-event (key 'down))))
(define s6 (feed engine s5 (app:key-event (key 'down))))
(define s7 (feed engine s6 (app:key-event (key 'enter))))
(check-equal? (resources-pending (state-resources s7)) v2)
;; 焦点移到右 panel
(define s8 (feed engine s7 (meta 'right)))
(check-equal? (state-focus s8) v1)
;; 提交替换
(define s9 (feed engine s8 (ctrl 'x)))
(define s10 (feed engine s9 (ctrl 'p)))
(check-equal? (state-focus s10) v2)
(check-false (resources-pending (state-resources s10)))
(check-equal? (region-active (workspace-view-region (state-workspace s10) v2)) v2)
(check-false (workspace-view-attached? (state-workspace s10) v1))
(check-true (engine-view-exists? engine v1)) ; 旧 view 只 detach，不销毁

;; 资源面板 Enter 到 attached view：设为 active + focus
(define s10r (feed engine s10 (meta 'left)))
(sync-resource-panel! s10r engine)
(define s10e (feed engine s10r (app:key-event (key 'enter))))
(check-equal? (state-focus s10e) v2)

;;; ════════════════ 面板内新建 document ════════════════

;; 焦点回资源面板，光标回到顶行
(define s11 (feed engine s10 (meta 'left)))
(check-equal? (state-focus s11) rvid)
(define s12 (feed engine s11 (plain #\n)))
(check-true (for/or ([(did dm) (in-hash (workspace-docs (state-workspace s12)))]
                     #:when (eq? (doc-meta-mode dm) 'text)
                     #:unless (equal? did d1))
              #t))

;; 资源面板自身 / 新建的 clean docs 不触发保存确认
(define s13 (feed engine s12 (ctrl 'q)))
(check-true (runtime-quit? (state-runtime s13)))

(displayln "edit-tui-rebuild resource-panel: ok")

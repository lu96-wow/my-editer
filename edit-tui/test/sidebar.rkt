#lang racket

;;; edit-tui/test/sidebar.rkt —— 文件树 + 资源列表共用一个面板位置，Tab 切换
;;;
;;; 断言：
;;;   1. 两次 install 传同一个 region-id -> 一个 region、两个成员，role 由第一次决定；
;;;   2. 后装的是 active（active 决定显示谁）；
;;;   3. Tab（全局 switch-member）把 active 切到另一个成员并聚焦它，再按一次切回来；
;;;   4. 不 active 的面板不重建 buffer（文件树被挡住时不扫盘）：
;;;      未显示时 buffer 为空，切换后才出现内容；
;;;   5. 只有一个成员的 region 按 Tab 只提示，不改任何状态；
;;;   6. chrome 槽（role 'slot，switch? = #f）拒绝 Tab 切换。

(require rackunit
         racket/async-channel
         "../command/key.rkt"
         (prefix-in app: "../base/event.rkt")
         "../base/id.rkt"
         "../base/keymap.rkt"
         "../base/transition.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../model/chrome.rkt"
         "../effects/engine.rkt"
         "../effects/panel.rkt"
         "../chrome/slot.rkt"
         "../env/environment.rkt"
         "../env/role.rkt"
         "../plugins/filetree/plugin.rkt"
         "../plugins/resource/plugin.rkt"
         "../plugins/builtin.rkt"
         "../runtime/run.rkt")

(define sidebar-rid (region-id 1))
(define editor-rid (region-id 2))
(define chrome-rid (region-id 3))

(define engine (make-engine))
(define s0 (make-state #:ids (make-id-counter 1 1 4 1)))

;; 同一个 region-id 装两个面板。
(define s1 (install-filetree-panel! engine s0 sidebar-rid (current-directory)))
(define s2 (install-resource-panel! engine s1 sidebar-rid))
(define ftv (filetree-panel-view s2))
(define rsv (resource-view s2))

;; 放进布局（sidebar 一个叶子；panel-visible? 还要看 region 是否可见）。
(define lay
  (make-split 'lr
              (list (make-leaf sidebar-rid (fixed 30) #:borders '(right))
                    (make-leaf editor-rid (flex 1)))
              (flex 1)))
(define s2l (state-set-workspace s2
                                 (struct-copy workspace (state-workspace s2) [layout lay])))

;;; ════════════════ 1. 一个 region、两个成员 ════════════════

(define ws (state-workspace s2l))
(check-equal? (hash-count (workspace-regions ws)) 1)
(define reg (workspace-region ws sidebar-rid))
(check-equal? (map region-member-key (region-members reg)) (list ftv rsv))
(check-equal? (region-role reg) 'filetree)     ; 第一次安装决定 role
(check-true (role-switchable? (environment-role default-env 'filetree)))

;;; ════════════════ 2. 后装的是 active ════════════════

(check-equal? (region-active reg) rsv)
(check-true (panel-visible? s2l rsv))
(check-false (panel-visible? s2l ftv))

;;; ════════════════ 3. Tab 切换 active + focus ════════════════

;; 键盘的 subject 是 focus：先把焦点放到当前 active 的面板上（真实应用里总是有焦点）。
(define s2f (state-set-focus s2l rsv))

(define (feed s . evs)
  (transition-state (process-events default-env engine (make-async-channel) s evs)))
(define tab (app:key-event (key 'tab)))

(define t1 (feed s2f tab))
(check-equal? (region-active (workspace-region (state-workspace t1) sidebar-rid)) ftv)
(check-equal? (state-focus t1) ftv)
(check-true (panel-visible? t1 ftv))
(check-false (panel-visible? t1 rsv))

(define t2 (feed t1 tab))
(check-equal? (region-active (workspace-region (state-workspace t2) sidebar-rid)) rsv)
(check-equal? (state-focus t2) rsv)

;; 循环：再按一次回到 filetree
(define t3 (feed t2 tab))
(check-equal? (region-active (workspace-region (state-workspace t3) sidebar-rid)) ftv)

;;; ════════════════ 4. 不 active 就不重建 buffer ════════════════

(define ev (make-engine-view engine))
(define (view-text vid) (or (engine-view-view-text ev vid) ""))

;; s2：active = resources -> 文件树没同步过
(sync-filetree-panel! s2f engine)
(sync-resource-panel! s2f engine)
(check-equal? (view-text ftv) "")
(check-true (string=? (view-text rsv) ""))   ; 没有用户文档，资源面板也是空的

;; 切到文件树后再同步 -> 有内容（第一行是根目录）
(define s3 (feed s2f tab))
(sync-filetree-panel! s3 engine)
(sync-resource-panel! s3 engine)
(check-true (string-contains? (view-text ftv) (filetree-normalize-path (current-directory))))

;; 切回资源列表：文件树保持上次内容（不再重建），资源列表被同步
(define s4 (feed s3 tab))
(sync-filetree-panel! s4 engine)
(sync-resource-panel! s4 engine)
(check-true (string-contains? (view-text ftv) (filetree-normalize-path (current-directory))))

;; 整个 region 被隐藏（C-b）时同样不同步
(define hidden
  (state-workspace* s3
                    (λ (ws)
                      (struct-copy workspace ws
                                   [layout (tree-hide (workspace-layout ws) sidebar-rid)]))))
(check-false (panel-visible? hidden ftv))

;;; ════════════════ 5. 单成员 region：Tab 只提示 ════════════════

(define-values (solo-base solo-vid)
  (panel-create-view! engine (make-state #:ids (make-id-counter 9 9 9 1)) #:name "*solo*"))
(define solo-state
  (state-set-focus
   (panel-region-add! solo-base editor-rid solo-vid #:role 'editor)
   solo-vid))
(define solo-after (feed solo-state tab))
(check-equal? (state-focus solo-after) (state-focus solo-state))
(check-true (string-contains? (chrome-message (state-chrome solo-after)) "single member"))

;;; ════════════════ 6. chrome 槽拒绝 Tab ════════════════

(define c1 (install-chrome! engine (make-state #:ids (make-id-counter 20 20 20 1)) chrome-rid))
(define crid (region-key (workspace-region (state-workspace c1) chrome-rid)))
(define svid (chrome-status-view c1))
(define c2 (state-set-focus c1 svid))
(define c3 (feed c2 tab))
(check-equal? (region-active (workspace-region (state-workspace c3) crid)) svid)
(check-true (string-contains? (chrome-message (state-chrome c3)) "not switchable"))

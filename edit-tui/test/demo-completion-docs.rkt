#lang racket

;;; completion + docs demo 的 headless 检查：
;;;   source / workspace 准备、补全弹窗、selection -> docs、接受插入、docs 显隐。

(require rackunit
         "../main.rkt"
         "../demo/completion-docs.rkt")

(define engine demo-engine)
(define state0 demo-state)

;; docs / completion 都是普通 engine buffer/view。
(check-not-false (engine-view-object engine 30))
(check-not-false (engine-view-object engine 40))

;; 初始帧：docs 面板可见，布局能渲染。
(check-true (layout-panel-visible? (app-state-layout state0) 'docs))
(define-values (s1 panels) (sync-ui/panels! state0 engine))
(define-values (s2 overlays) (prepare-demo! s1 engine))
(check-not-false (hash-ref (app-state-store s2) 'demo/source #f))
(check-equal? overlays '())
(define-values (_c1 bytes1)
  (render-frame s2 engine #f #:panels panels #:overlays overlays))
(check-true (> (bytes-length bytes1) 0))

;; C-o 打开补全。
(define-values (s3 acts3) (step s2 (key-event (key 'o 'ctrl))))
(check-equal? acts3 '())
(check-not-false (hash-ref (app-state-store s3) 'demo/completion #f))
(check-not-false (app-state-key-owner-stack s3))

;; 弹窗渲染 + 候选里有本地 twice。
(define-values (s4 panels4) (sync-ui/panels! s3 engine))
(define-values (s5 overlays5) (prepare-demo! s4 engine))
(check-equal? (length overlays5) 1)
(define-values (_c2 bytes2)
  (render-frame s5 engine #f #:panels panels4 #:overlays overlays5))
(check-true (string-contains? (bytes->string/utf-8 bytes2) "twice"))
(check-false (string-contains? (engine-view-text engine 40) ">"))

;; 焦点转移：docs 隐藏时，C-x o 从补全菜单进入 docs，补全不关闭。
(define-values (h1 h1a) (step s5 (key-event (key 'x 'ctrl))))
(define-values (h2 h2a) (step h1 (key-event (key 'd))))
(check-false (layout-panel-visible? (app-state-layout h2) 'docs))

(define-values (d1 d1a) (step h2 (key-event (key 'x 'ctrl))))
(define-values (d2 d2a) (step d1 (key-event (key 'o))))
(check-true (layout-panel-visible? (app-state-layout d2) 'docs))
(check-equal? (app-state-focus-panel-id d2) 'docs)
(check-not-false (hash-ref (app-state-store d2) 'demo/completion #f))

;; docs 获得焦点后，弹窗仍然存在；Down 移动 docs 光标，而不是补全候选。
(define-values (d3 panelsd) (sync-ui/panels! d2 engine))
(define-values (d4 ovsd) (prepare-demo! d3 engine))
(check-equal? (length ovsd) 1)
(check-false (app-state-key-owner-stack d4))
(define docs-line-before (engine-view-point-line engine 30))
(define-values (d5 acts5) (step d4 (key-event (key 'down))))
(define d6 (run-actions d5 engine acts5))
(check-equal? (engine-view-point-line engine 30) (add1 docs-line-before))
(check-not-false (hash-ref (app-state-store d6) 'demo/completion #f))

;; C-x o 返回补全菜单，焦点回 editor，弹窗仍在。
(define-values (m1 m1a) (step d6 (key-event (key 'x 'ctrl))))
(define-values (m2 m2a) (step m1 (key-event (key 'o))))
(check-equal? (app-state-focus-panel-id m2) 'editor)
(check-not-false (hash-ref (app-state-store m2) 'demo/completion #f))
(define-values (m3 panelsm) (sync-ui/panels! m2 engine))
(define-values (m4 ovsm) (prepare-demo! m3 engine))
(check-equal? (length ovsm) 1)

;; 普通换焦点路径：C-x ↓ 进入 docs，不经过 C-x o 特判，也必须退出补全键表。
(define-values (g1 g1a) (step m4 (key-event (key 'x 'ctrl))))
(define-values (g2 g2a) (step g1 (key-event (key 'down))))
(check-equal? (app-state-focus-panel-id g2) 'docs)
(check-not-false (hash-ref (app-state-store g2) 'demo/completion #f))
(define-values (g3 panelsg) (sync-ui/panels! g2 engine))
(define-values (g4 ovsg) (prepare-demo! g3 engine))
(check-equal? (length ovsg) 1)
(define docs-line-g (engine-view-point-line engine 30))
(define-values (g5 actsg) (step g4 (key-event (key 'down))))
(check-equal? (map view-action-kind actsg) '(nav))
(check-equal? (map view-action-view-id actsg) (list 30))
(define g6 (run-actions g5 engine actsg))
(check-equal? (engine-view-point-line engine 30) (add1 docs-line-g))
(check-not-false (hash-ref (app-state-store g6) 'demo/completion #f))
;; 下一帧内容没变，光标必须保留，不能被 sync 重置。
(define-values (g6b panelsg6) (sync-ui/panels! g6 engine))
(define-values (g6c ovsg6) (prepare-demo! g6b engine))
(check-equal? (engine-view-point-line engine 30) (add1 docs-line-g))
(check-equal? (length ovsg6) 1)
(check-false (app-state-key-owner-stack g6c))

;; left / up 也归 docs，而不是补全菜单。
(define-values (_gl acts-left) (step g6 (key-event (key 'left))))
(check-equal? (map view-action-kind acts-left) '(nav))
(check-equal? (map view-action-view-id acts-left) (list 30))
(define-values (_gu acts-up) (step g6 (key-event (key 'up))))
(check-equal? (map view-action-kind acts-up) '(nav))
(check-equal? (map view-action-view-id acts-up) (list 30))

;; 从 docs 返回菜单。
(define-values (r1 r1a) (step g6 (key-event (key 'x 'ctrl))))
(define-values (r2 r2a) (step r1 (key-event (key 'o))))
(check-equal? (app-state-focus-panel-id r2) 'editor)
(define-values (r3 panelsr) (sync-ui/panels! r2 engine))
(define-values (r4 ovsr) (prepare-demo! r3 engine))
(check-equal? (length ovsr) 1)
(check-not-false (app-state-key-owner-stack r4))

;; Enter 接受；目标 view 插入剩余后缀。
(define before-text (engine-view-text engine 1))
(define-values (s6 acts6) (step r4 (key-event (key 'enter))))
(check-true (pair? acts6))
(define s7 (run-actions s6 engine acts6))
(define after-text (engine-view-text engine 1))
(check-true (string-contains? after-text "twice"))
(check-true (> (string-length after-text) (string-length before-text)))
(check-false (hash-ref (app-state-store s7) 'demo/completion #f))

;; C-x d 隐藏 docs；再按一次显示。
(define-values (s8 _a8) (step s7 (key-event (key 'x 'ctrl))))
(define-values (s9 _a9) (step s8 (key-event (key 'd))))
(check-false (layout-panel-visible? (app-state-layout s9) 'docs))
(define-values (s10 _a10) (step s9 (key-event (key 'x 'ctrl))))
(define-values (s11 _a11) (step s10 (key-event (key 'd))))
(check-true (layout-panel-visible? (app-state-layout s11) 'docs))


;; 小终端 / overlay 压住低层边框时也不能崩（border 合成的回归）。
(define small-state (struct-copy app-state s5 [area (rect 0 0 40 10)]))
(define-values (ss1 sps) (sync-ui/panels! small-state engine))
(define-values (ss2 sovs) (prepare-demo! ss1 engine))
(check-true (pair? sovs))
(define-values (_sc _sb)
  (render-frame ss2 engine #f #:panels sps #:overlays sovs))
(check-true #t)

(displayln "edit-tui-rebuild/test/demo-completion-docs.rkt: ok")

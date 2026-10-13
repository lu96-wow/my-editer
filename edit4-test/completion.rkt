#lang racket

;;; edit4-test/completion.rkt —— 补全 + 文档插件（菜单 / 异步 job / 录入）

(require rackunit racket/list racket/path
         "../edit4/app.rkt" "../edit4/env.rkt" "../edit4/boot.rkt" "../edit4/plugin.rkt"
         "../edit4/core/world.rkt" "../edit4/core/event.rkt"
         "../edit4/core/command.rkt" "../edit4/core/dispatch.rkt" "../edit4/core/keymap.rkt"
         "../edit4/core/hook.rkt" "../edit4/core/job.rkt"
         "../edit4/content/model.rkt" "../edit4/content/adapter.rkt" "../edit4/content/float.rkt"
         "../edit4/view/panel.rkt" "../edit4/view/render.rkt" "../edit4/layout.rkt")

(define env (app-environment))

(define (send w ev)
  (define-values (w* _effs)
    (dispatch (environment-commands env) (environment-scopes env)
              (environment-keymap env) (ctx ev (cons 60 10) #f) w))
  w*)
(define (hooks w) (run-hooks (environment-hooks env) w))

(define (panel-vid w name) (content-panel-vid (world-content w) name))
(define (panel-text w name)
  (for/first ([p (in-list (project-panels (environment-panels env) w))]
              #:when (eqv? (car p) (panel-vid w name)))
    (cadr p)))
(define (float-of-panel w name)
  (define v (panel-vid w name))
  (and v (for/first ([f (in-list (world-floats w))]
                     #:when (eqv? v (content-vid-of (world-content w) (float-id f))))
           (float-id f))))
(define (line w vid i)
  (list-ref (string-split (view-string (content-ed (world-content w)) vid) "\n") i))

;; 注意：boot 不跑插件 boot（runtime 才跑）；测试里显式 run-boots 初始化插件缓存。
;; 用 #:regions '() 只用编辑器（不受默认 dock 布局/尺寸影响）。
(define (scratch text path)
  (run-boots env (boot #:env env #:name (or path "*scratch*")
                       #:path (and path (string->path path)) #:text text #:regions '())))
(define (focus-first! w)
  (define v (content-vid-of (world-content w) 0))
  v)

;;; ---------- 补全：非 Racket 文档 → 本地池同步开菜单 ----------

(define a0 (scratch "hello\nhel" #f))
(define av (focus-first! a0))
(set-point! (content-ed (world-content a0)) av 1 3)

(define a1 (send a0 (key-event '/ '(alt))))
(check-not-false (float-of-panel a1 "*completion*"))            ; 菜单浮窗
(check-true (regexp-match? #rx"hello" (panel-text a1 "*completion*")))
(check-true (for/or ([s (in-list (world-signals a1))])          ; 广播 complete-selection
              (eq? (car s) 'complete-selection)))

;; before-render 重算菜单落位（world-frame / 浮窗矩形）
(define a1b (hooks (emit! a1 'before-render (list (cons 60 10)))))
(check-not-false (float-of-panel a1b "*completion*"))

;; 渲染：浮窗内容四边内缩 1 格（框不压内容）→ 第一项（选中）在框内第一行
(define ac (world-content a1b))
(define aed (content-ed ac))
(commit-panels! aed (project-panels (environment-panels env) a1b))
(define afr (world-frame a1b (cons 60 10)))
(define afid (float-of-panel a1b "*completion*"))
(define arect (frame-float-content-rect afr afid))
(define-values (_asc arends asels)
  (render-frame aed afr (lambda (id) (content-vid-of ac id)) (content-vid-of ac 0) 60 10 #f))
(define asel (for/first ([p (in-list (append arends asels))]
                         #:when (eq? 'complete-selected (piece-attr p))) p))
(check-true (and asel (= (piece-row asel) (rect-y arect))
                 (= (piece-column asel) (rect-x arect))))
(check-true (= (string-length (piece-text asel)) (rect-w arect)))   ; 选中行底色铺满浮窗内容宽

;; 打字 → after-insert 钩子重筛
(define a2 (send a1 (text-event "l")))
(define a3 (hooks a2))
(check-equal? (line a3 av 1) "hell")
(check-true (regexp-match? #rx"hello" (panel-text a3 "*completion*")))

;; 不过滤完全匹配的串：菜单里 "hel" 也在（不排除）
(check-true (for/or ([l (in-list (string-split (panel-text a1 "*completion*") "\n"))])
              (string=? (string-trim l) "hel")))

;; Enter 接受候选（补全余下 "o"）
(define a4 (send a3 (key-event 'enter '())))
(check-equal? (line a4 av 1) "hello")
(check-false (float-of-panel a4 "*completion*"))                ; 接受后菜单关

;; Esc 关菜单（不插字）—— 独立的 World / 引擎
(define e0 (scratch "hello\nhel" #f))
(define ev (focus-first! e0))
(set-point! (content-ed (world-content e0)) ev 1 3)
(define e1 (send e0 (key-event '/ '(alt))))
(check-not-false (float-of-panel e1 "*completion*"))
(define e2 (send e1 (key-event 'escape '())))
(check-false (float-of-panel e2 "*completion*"))
(check-equal? (line e2 ev 1) "hel")

;;; ---------- 补全：Racket 文档 → 异步 job，回来后开菜单 ----------

(define r0 (scratch "(define alpha 1)\n(al" "/tmp/ed4-comp.rkt"))
(define rv (focus-first! r0))
(set-point! (content-ed (world-content r0)) rv 1 3)
(define r1 (send r0 (key-event '/ '(alt))))
(check-true (>= (length (jobs r1)) 1))                          ; 有在途 job
(check-false (float-of-panel r1 "*completion*"))                ; 还没开菜单

;; 模拟 worker 结果回来
(define j (car (jobs r1)))
(define res '("alpha" "allocation"))
(define r2 (job-finish r1 (job-id j) res))
(define r3 (hooks (emit! r2 'job (list (job-id j) 'completion-exports res (job-tag j)))))
(check-not-false (float-of-panel r3 "*completion*"))
(check-true (regexp-match? #rx"alpha" (panel-text r3 "*completion*")))
;; 候选按长度排序：短在前（文件里的 “al” < alpha < allocation）
(check-equal? (for/list ([l (in-list (string-split (panel-text r3 "*completion*") "\n"))])
                (string-trim l))
              '("al" "alpha" "allocation"))

;; 补全菜单在最上：文档弹窗后开也不能盖住它（跑一帧 before-render，补全重新提到表头）
(define r4 (hooks (emit! r3 'before-render (list (cons 60 10)))))
(define cfl (float-of-panel r4 "*completion*"))
(define dfl (float-of-panel r4 "*docs*"))
(check-not-false cfl)
(check-not-false dfl)
(define zorder (map float-id (world-floats r4)))
(check-true (< (index-of zorder cfl) (index-of zorder dfl)))

;; 补全/文档都不遮输入行（状态 dock）：两个浮窗都落在编辑区内
(define fr4 (world-frame r4 (cons 60 10)))
(define area4 (frame-editing-area fr4 r4))
(check-not-false area4)
(for ([fid (in-list (list cfl dfl))])
  (define mr (frame-float-rect fr4 fid))
  (check-true (and (>= (rect-y mr) (rect-y area4))
                   (<= (rect-bottom mr) (rect-bottom area4)))))

;;; ---------- 文档：M-d 打开本地定义 ----------

(define d0 (scratch "(define foo 1)" "/tmp/ed4-docs.rkt"))
(define dv (focus-first! d0))
(set-point! (content-ed (world-content d0)) dv 0 8)
(define d1 (send d0 (key-event 'd '(alt))))
(check-not-false (float-of-panel d1 "*docs*"))
(check-true (regexp-match? #rx"foo" (panel-text d1 "*docs*")))
(check-true (regexp-match? #rx"本地定义" (panel-text d1 "*docs*")))
(check-true (>= (length (jobs d1)) 1))                          ; 标准库查询在途

;; before-render 重算文档落位
(define d1b (hooks (emit! d1 'before-render (list (cons 60 10)))))
(check-not-false (float-of-panel d1b "*docs*"))

;; after-nav 关文档浮窗
(define d2 (hooks (emit! d1 'after-nav (list dv))))
(check-false (float-of-panel d2 "*docs*"))

(displayln "edit4/completion.rkt: all tests passed")

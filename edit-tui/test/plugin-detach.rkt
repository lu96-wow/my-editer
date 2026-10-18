#lang racket

;;; edit-tui/test/plugin-detach.rkt —— “面板/插件真的可拆”的基线
;;;
;;; 断言：
;;;   1. core-env 不含任何内置插件的东西（mode / command / 规则 / panel-sync）；
;;;   2. 只用 core-env 也能跑编辑 / 切分 / 关闭 / 退出（不 require 插件即无面板）；
;;;   3. default-env = core-env + 内置插件（命令与同步器都在，而且互不覆盖）；
;;;   4. 插件贡献全局键用的是规则（不会覆盖 'global 表）；
;;;   5. panel-spec-install! 装出来的面板与 install-*-panel! 同一身份（name/role/mode）。
;;;
;;; 第 1、2 条就是“拆掉文件树 / 资源面板插件后框架仍然成立”的证明。

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
         "../plugins/filetree/model.rkt"
         "../plugins/resource/model.rkt"
         "../effects/engine.rkt"
         "../env/environment.rkt"
         "../env/mode.rkt"
         "../env/input-command.rkt"
         "../env/command.rkt"
         "../dispatch/pipeline.rkt"
         "../dispatch/rules.rkt"
         "../effects/panel.rkt"
         "../bootstrap/panel.rkt"
         "../env/plugin.rkt"
         "../bootstrap/defaults.rkt"
         "../plugins/builtin.rkt"
         "../plugins/filetree/plugin.rkt"
         "../plugins/resource/plugin.rkt"
         "../runtime/run.rkt")

;;; ════════════════ 1. core-env 是干净的 ════════════════

(check-true (environment? core-env))
;; 没有插件的 mode
(check-false (hash-has-key? (environment-modes core-env) 'filetree))
(check-false (hash-has-key? (environment-modes core-env) 'resources))
(check-true (hash-has-key? (environment-modes core-env) 'text))
;; 没有插件的命令
(check-false (environment-command core-env 'toggle-filetree))
(check-false (environment-command core-env 'resource-enter))
;; 没有插件的输入命令
(check-false (for/or ([c (in-list (environment-input-commands core-env))])
               (eq? (input-command-name c) 'filetree-create-file)))
;; 没有面板同步器
(check-equal? (environment-panel-syncs core-env) '())
;; 框架自己的命令还在
(check-true (command? (environment-command core-env 'request-quit)))
(check-true (command? (environment-command core-env 'split-right)))
;; placement 是框架级的，core-env 里就有
(check-true (command? (environment-command core-env 'place-commit)))
(check-true (for/or ([r (in-list (environment-rules core-env))])
              (eq? (rule-scope r) 'placing)))

;;; ════════════════ 2. 只用 core-env 也能跑 ════════════════

(define did (doc-id 1))
(define vid (view-id 1))
(define erid (region-id 1))
(define engine (make-engine))
(void (engine-create-doc! engine did "main.rkt" "abc\n"))
(void (engine-create-view! engine vid did))

(define ws
  (let* ([ws (workspace-empty)]
         [ws (workspace-add-doc ws did
                                (make-doc-meta "main.rkt" #:path "/tmp/main.rkt"
                                               #:saved-version
                                               (engine-view-doc-version
                                                (make-engine-view engine) did)))]
         [ws (workspace-add-view ws vid (view-meta did (hash)))]
         [ws (workspace-add-region ws erid (region erid (list (view-member vid)) vid 'editor))])
    ws))
(define s0
  (state-set-focus
   (state-set-workspace (make-state #:workspace ws #:ids (make-id-counter 2 2 2 1))
                        (struct-copy workspace ws [layout (make-leaf erid (flex 1))]))
   vid))

(define (feed env s . evs)
  (transition-state (process-events env engine (make-async-channel) s evs)))
(define (plain c) (app:key-event (key c)))
(define (ctrl c)  (app:key-event (key c 'ctrl)))
(define (ev) (make-engine-view engine))

;; 编辑：core-env 的 text mode 就够
(define s1 (feed core-env s0 (plain #\x)))
(check-equal? (engine-view-doc-text (ev) did) "xabc\n")
;; 切分：role 'editor 可切
(define s2 (feed core-env s1 (ctrl 'w) (app:key-event (key 'right))))
(check-equal? (hash-count (workspace-regions (state-workspace s2))) 2)
;; 关闭一个 view
(define s3 (feed core-env s2 (ctrl 'w) (ctrl 'w)))
;; 退出：文档 dirty -> 进保存确认（框架行为，与插件无关）
(define s-quit-dirty (feed core-env s3 (ctrl 'q)))
(check-not-false (state-confirm s-quit-dirty))
(check-false (runtime-quit? (state-runtime s-quit-dirty)))
;; 干净文档 -> 直接退出（把 saved-version 对齐到当前 engine 版本）
(define s-clean
  (state-workspace* s0
                    (λ (ws)
                      (workspace-add-doc
                       ws did
                       (struct-copy doc-meta (workspace-doc ws did)
                                    [saved-version
                                     (engine-view-doc-version (make-engine-view engine) did)])))))
(check-true (runtime-quit? (state-runtime (feed core-env s-clean (ctrl 'q)))))
;; 插件快捷键在 core-env 下不生效（C-b 未绑定 -> unbound 提示，不建面板）
(define s4 (feed core-env s3 (ctrl 'b)))
(check-true (string-contains? (chrome-message (state-chrome s4)) "unbound"))
(check-equal? (hash-count (workspace-docs (state-workspace s4))) 1)

;;; ════════════════ 3. default-env = core + 内置插件 ════════════════

(check-true (hash-has-key? (environment-modes default-env) 'filetree))
(check-true (hash-has-key? (environment-modes default-env) 'resources))
(check-true (command? (environment-command default-env 'toggle-filetree)))
(check-true (command? (environment-command default-env 'resource-enter)))
(check-equal? (length (environment-panel-syncs default-env)) 2)
;; core 的命令没有被吞掉
(check-true (command? (environment-command default-env 'request-quit)))
(check-true (command? (environment-command default-env 'split-right)))
;; C-b 在 default-env 下命中 toggle-filetree（插件用规则加，而不是覆盖 global 表）
(define (key-command env subject . toks)
  (define-values (st v) (lookup-rules (rules-for env s0 subject) toks))
  (and (eq? st 'leaf) v))
(check-eq? (key-command default-env vid (key 'b 'ctrl)) 'toggle-filetree)
;; 插件的规则没有覆盖框架的 global 表：C-x C-f 仍然是 open-file（前缀 + 第二键）
(check-eq? (key-command default-env vid (key 'x 'ctrl) (key 'f 'ctrl)) 'open-file)
(check-eq? (key-command core-env vid (key 'x 'ctrl) (key 'f 'ctrl)) 'open-file)
;; core-env 下 C-b 没有规则命中
(check-false (key-command core-env vid (key 'b 'ctrl)))

;;; ════════════════ 4. panel-spec-install! 与 install-*-panel! 同身份 ════════════════

(define e2 (make-engine))
(define (fresh) (make-state #:ids (make-id-counter 1 1 3 1)))

(define-values (a1 avid) (panel-spec-install! e2 (fresh) (region-id 1) (filetree-panel-spec)))
(define aws (state-workspace a1))
(define adm (workspace-doc aws (view-meta-doc (workspace-view aws avid))))
(check-equal? (doc-meta-name adm) "*filetree*")
(check-equal? (doc-meta-mode adm) 'filetree)
(check-true (doc-meta-internal? adm))
(check-equal? (region-role (workspace-region aws (region-id 1))) 'filetree)

(define b1 (install-filetree-panel! e2 (fresh) (region-id 1) (current-directory)))
(define bvid (filetree-panel-view b1))
(define bws (state-workspace b1))
(define bdm (workspace-doc bws (view-meta-doc (workspace-view bws bvid))))
;; install-filetree-panel! ≡ panel-spec-install! + root/expanded
(check-equal? (doc-meta-name bdm) "*filetree*")
(check-equal? (doc-meta-mode bdm) 'filetree)
(check-equal? (region-role (workspace-region bws (region-id 1))) 'filetree)
(check-true (string=? (workspace-root bws)
                      (filetree-normalize-path (current-directory))))

;; 资源插件同理
(define r1 (install-resource-panel! e2 (fresh) (region-id 1)))
(define rws (state-workspace r1))
(define rvid (resource-view r1))
(define rdm (workspace-doc rws (view-meta-doc (workspace-view rws rvid))))
(check-equal? (doc-meta-name rdm) "*resources*")
(check-equal? (region-role (workspace-region rws (region-id 1))) 'resource)
(check-true (doc-meta-internal? rdm))

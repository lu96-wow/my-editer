#lang racket

;;; layer  : env
;;; effect : 无（纯值 + 纯校验）
;;;
;;; env/extension.rkt —— 统一的“插件贡献”描述 + 装配期校验
;;;
;;; 背景：环境里已经有 13 张表（commands / rules / hooks / decors / panel-syncs …）。
;;; 如果每加一个功能就再加一张表 / 一个 hook，扩展点会越来越碎。这里不再新增
;;; 执行器，只加一层**清单**：
;;;
;;;   contribution = owner + kind + payload
;;;
;;; owner 用来记录“这条贡献来自哪个插件”；kind 决定它落到哪张现有表；
;;; payload 是该 kind 的原生值（command / rule / hook / face-decor / panel-spec …）。
;;;
;;; 执行路径完全不变：
;;;   command     -> dispatch/pipeline
;;;   rule/keymap -> dispatch/rules
;;;   hook        -> dispatch/hooks
;;;   decor       -> effects/paint
;;;   panel-sync  -> runtime/run-frame
;;;   panel       -> bootstrap/panel + panel-sync
;;;
;;; 这个模块只依赖 env 层（外加 base / model 的纯值谓词），不依赖 effects / runtime。
;;;
;;; 约定：
;;;   · 新扩展点优先复用已有 kind；
;;;   · 只有“触发时机 + 纯度 + 生命周期”真的不同，才加新 kind；
;;;   · kind 在装配期校验，拼错 / 指向不存在的命令 / 未声明的 layer 都直接报错。

(provide (struct-out contribution)
         make-contribution
         contribution-kinds
         contribution-kind?
         environment-add-contribution
         environment-add-contributions
         environment-attach-contributions
         environment-strip-contributions
         environment->contributions
         environment-remove-owner
         environment-owner-contributions
         (struct-out validation-error)
         validate-environment
         validate-environment!
         environment-valid?)

(require racket/list
         racket/string
         "../base/keymap.rkt"
         "../base/status-part.rkt"
         "../model/face-decor.rkt"
         "../model/layout.rkt"
         "environment.rkt"
         "role.rkt"
         "mode.rkt"
         "scope.rkt"
         "command.rkt"
         "rule.rkt"
         "doc-type.rkt"
         "input-command.rkt"
         "hook.rkt"
         "panel-spec.rkt"
         "service.rkt")

;;; ════════════════ 贡献描述 ════════════════

;; 这些 kind 都能落到 environment 的现有字段；没有新增执行器。
(define contribution-kinds
  '(status status-parts status-part
    command keymap rule mode scope role doc-type input-command
    panel panel-sync hook decor face-layer interaction service continuation))

(define (contribution-kind? k)
  (and (memq k contribution-kinds) #t))

(struct contribution (owner kind payload) #:transparent)
;; owner   : symbol
;; kind    : symbol（见 contribution-kinds）
;; payload : kind-specific
;;
;;   status         #f | (listof status-part)   （替换语义，用于 plugin.env 的 :status）
;;   status-parts   (listof status-part)         （加法语义，用于 plugin.status-parts）
;;   status-part    status-part
;;   command        (cons symbol command)
;;   keymap         (cons symbol keymap)
;;   rule           rule
;;   mode           (cons symbol mode)
;;   scope          (cons symbol scope)
;;   role           (cons symbol role)
;;   doc-type       doc-type
;;   input-command  input-command
;;   panel          panel-spec
;;   panel-sync     (state engine -> any)
;;   hook           hook
;;   decor          face-decor
;;   face-layer     symbol
;;   interaction    (cons symbol handler)   handler : (ctx data -> transition)
;;   service        service-spec
;;   continuation   (cons symbol handler)   handler : (state data . results -> transition)

(define (make-contribution owner kind payload)
  (unless (symbol? owner)
    (error 'make-contribution "owner 要是 symbol：~a" owner))
  (unless (contribution-kind? kind)
    (error 'make-contribution "未知 contribution kind：~a（可用：~a）"
           kind contribution-kinds))
  (contribution owner kind payload))

;;; ════════════════ 装配：contribution -> 现有 env 字段 ════════════════

(define (environment-add-contribution env c)
  (unless (contribution? c)
    (error 'environment-add-contribution "要 contribution：~a" c))
  (define kind (contribution-kind c))
  (define p (contribution-payload c))
  (define base (or (environment-base env)
                   (environment-strip-contributions env)))
  (define env*
    (case kind
      [(status)
       (unless (or (not p) (and (list? p) (andmap status-part? p)))
         (error 'environment-add-contribution "status payload 要是 #f 或 status-part list：~a" p))
       (struct-copy environment env [status p])]
      [(status-parts)
       (unless (list? p)
         (error 'environment-add-contribution "status-parts payload 要是 list：~a" p))
       (environment-add-status-parts env p)]
      [(status-part)
       (unless (status-part? p)
         (error 'environment-add-contribution "status-part payload 要是 status-part：~a" p))
       (environment-add-status-part env p)]
      [(command)
       (unless (and (pair? p) (symbol? (car p)) (command? (cdr p)))
         (error 'environment-add-contribution "command payload 要是 (cons symbol command)：~a" p))
       (environment-add-command env (car p) (cdr p))]
      [(keymap)
       (unless (and (pair? p) (symbol? (car p)) (keymap? (cdr p)))
         (error 'environment-add-contribution "keymap payload 要是 (cons symbol keymap)：~a" p))
       (environment-add-keymap env (car p) (cdr p))]
      [(rule)
       (unless (rule? p)
         (error 'environment-add-contribution "rule payload 要是 rule：~a" p))
       (environment-add-rule env p)]
      [(mode)
       (unless (and (pair? p) (symbol? (car p)) (mode? (cdr p)))
         (error 'environment-add-contribution "mode payload 要是 (cons symbol mode)：~a" p))
       (environment-add-mode env (car p) (cdr p))]
      [(scope)
       (unless (and (pair? p) (symbol? (car p)) (scope? (cdr p)))
         (error 'environment-add-contribution "scope payload 要是 (cons symbol scope)：~a" p))
       (environment-add-scope env (car p) (cdr p))]
      [(role)
       (unless (and (pair? p) (symbol? (car p)) (role? (cdr p)))
         (error 'environment-add-contribution "role payload 要是 (cons symbol role)：~a" p))
       (environment-add-role env (car p) (cdr p))]
      [(doc-type)
       (unless (doc-type? p)
         (error 'environment-add-contribution "doc-type payload 要是 doc-type：~a" p))
       (environment-add-doc-type env p)]
      [(input-command)
       (unless (input-command? p)
         (error 'environment-add-contribution "input-command payload 要是 input-command：~a" p))
       (environment-add-input-command env p)]
      [(panel)
       (unless (panel-spec? p)
         (error 'environment-add-contribution "panel payload 要是 panel-spec：~a" p))
       ;; 面板的每帧 sync 仍挂到 env.panel-syncs；面板本身留在 contributions 里，
       ;; 由宿主 panel-spec-install! / install-* 决定落在哪个 region。
       (if (panel-spec-sync p)
           (environment-add-panel-sync env (panel-spec-sync p))
           env)]
      [(panel-sync)
       (unless (procedure? p)
         (error 'environment-add-contribution "panel-sync payload 要是过程：~a" p))
       (environment-add-panel-sync env p)]
      [(hook)
       (unless (hook? p)
         (error 'environment-add-contribution "hook payload 要是 hook：~a" p))
       (environment-add-hook env p)]
      [(decor)
       (unless (face-decor? p)
         (error 'environment-add-contribution "decor payload 要是 face-decor：~a" p))
       (environment-add-decor env p)]
      [(face-layer)
       (unless (symbol? p)
         (error 'environment-add-contribution "face-layer payload 要是 symbol：~a" p))
       (environment-add-face-layer env p)]
      [(interaction)
       (unless (and (pair? p) (symbol? (car p)) (procedure? (cdr p)))
         (error 'environment-add-contribution
                "interaction payload 要是 (cons symbol handler)：~a" p))
       (environment-add-interaction env (car p) (cdr p))]
      [(service)
       (unless (service-spec? p)
         (error 'environment-add-contribution "service payload 要是 service-spec：~a" p))
       (environment-add-service env p)]
      [(continuation)
       (unless (and (pair? p) (symbol? (car p)) (procedure? (cdr p)))
         (error 'environment-add-contribution
                "continuation payload 要是 (cons symbol handler)：~a" p))
       (environment-add-continuation env (car p) (cdr p))]
      [else
       (error 'environment-add-contribution "未知 kind：~a" kind)]))
  (struct-copy environment env*
               [base base]
               [contributions (append (environment-contributions env*) (list c))]))

(define (environment-add-contributions env cs)
  (for/fold ([e env]) ([c (in-list cs)])
    (environment-add-contribution e c)))

;;; ════════════════ 分解 / 附挂 / 按 owner 重建 ════════════════

;; 丢掉 provenance，只留编译后的字段。用于给插件 env 建 base 快照，
;; 以及避免把 plugin.env 里已有的 contributions 重复展开。
(define (environment-strip-contributions env)
  (struct-copy environment env [contributions '()] [base #f]))

;; 只把 contribution 记到清单里，不重新编译字段。
;; 用于 plugin-env-apply：字段已经通过 environment-merge 合并过，重建时再由
;; environment-add-contributions 按清单重放。
(define (environment-attach-contributions env cs)
  (struct-copy environment env
               [contributions (append (environment-contributions env) cs)]))

;; 把一个 environment 分解成 contribution（owner 统一指定）。
;;
;; 注意：
;;   · rules / input-commands 是“cons 到前面”的表，所以这里反向生成，
;;     这样 environment-add-contributions 重放后顺序不变；
;;   · status 用 'status（替换语义），不是 'status-parts（加法语义）；
;;   · contributions 字段本身被忽略（调用方通常先 strip）。
(define (environment->contributions env owner)
  (define (mk kind payload) (make-contribution owner kind payload))
  (append
   (for/list ([(id c) (in-hash (environment-commands env))])
     (mk 'command (cons id c)))
   (for/list ([(name km) (in-hash (environment-keymaps env))])
     (mk 'keymap (cons name km)))
   (for/list ([(id m) (in-hash (environment-modes env))])
     (mk 'mode (cons id m)))
   (for/list ([(id s) (in-hash (environment-scopes env))])
     (mk 'scope (cons id s)))
   (for/list ([(id r) (in-hash (environment-roles env))])
     (mk 'role (cons id r)))
   (for/list ([(id dt) (in-hash (environment-doc-types env))])
     (mk 'doc-type dt))
   ;; cons 表：反向，重放时 cons 回原顺序
   (for/list ([r (in-list (reverse (environment-rules env)))])
     (mk 'rule r))
   (if (environment-status env)
       (list (mk 'status (environment-status env)))
       '())
   (for/list ([c (in-list (reverse (environment-input-commands env)))])
     (mk 'input-command c))
   ;; append 表：正序
   (for/list ([f (in-list (environment-panel-syncs env))])
     (mk 'panel-sync f))
   (for/list ([h (in-list (environment-hooks env))])
     (mk 'hook h))
   (for/list ([l (in-list (environment-face-layers env))])
     (mk 'face-layer l))
   (for/list ([d (in-list (environment-decors env))])
     (mk 'decor d))
   (for/list ([(kind handler) (in-hash (environment-interactions env))])
     (mk 'interaction (cons kind handler)))
   (for/list ([spec (in-hash-values (environment-services env))])
     (mk 'service spec))
   (for/list ([(tag handler) (in-hash (environment-continuations env))])
     (mk 'continuation (cons tag handler)))))

;; 从 base 重建，去掉某 owner 的全部 contribution。
;; 要求 env 有 base 快照（plugins-env 会在第一个插件贡献前自动写）。
(define (environment-remove-owner env owner)
  (define base (environment-base env))
  (unless base
    (error 'environment-remove-owner
           "环境没有 base 快照，无法按 owner 重建：~a" owner))
  (define all (environment-contributions env))
  (define keep (for/list ([c (in-list all)]
                          #:unless (eq? (contribution-owner c) owner))
                 c))
  (if (= (length keep) (length all))
      env
      (environment-add-contributions base keep)))


(define (environment-owner-contributions env owner)
  (for/list ([c (in-list (environment-contributions env))]
             #:when (eq? (contribution-owner c) owner))
    c))

;;; ════════════════ 校验 ════════════════

(struct validation-error (where message) #:transparent)
;; where   : symbol（大致位置：'contributions / 'commands / 'keymaps / …）
;; message : string

(define (err where fmt . args)
  (validation-error where (apply format fmt args)))

;; keymap trie 里的叶子值
(define (keymap-leaf-values km)
  (append*
   (for/list ([(k v) (in-hash (keymap-bindings km))])
     (if (binding? v)
         (list (binding-value v))
         (keymap-leaf-values v)))))

(define (check-keymap where km commands out)
  (define errs
    (for/list ([v (in-list (keymap-leaf-values km))]
               #:unless (and (symbol? v) (hash-has-key? commands v)))
      (err where "keymap 叶子 ~a 不是已注册命令" v)))
  (append out errs))

(define (check-unique-name where name items name-of out)
  (define seen (make-hash))
  (for/fold ([errs out]) ([x (in-list items)])
    (define n (name-of x))
    (cond
      [(hash-ref seen n #f)
       (append errs (list (err where "重名：~a" n)))]
      [else (hash-set! seen n #t) errs])))

(define (validate-environment env)
  (define out '())
  (define (add! e) (set! out (append out (list e))))
  (define (add-all! es) (set! out (append out es)))
  (define commands (environment-commands env))
  (define modes (environment-modes env))
  (define roles (environment-roles env))
  (define scopes (environment-scopes env))

  ;; 1. contributions：owner / kind
  (for ([c (in-list (environment-contributions env))])
    (unless (contribution? c)
      (add! (err 'contributions "不是 contribution：~a" c)))
    (when (contribution? c)
      (unless (symbol? (contribution-owner c))
        (add! (err 'contributions "owner 不是 symbol：~a" c)))
      (unless (contribution-kind? (contribution-kind c))
        (add! (err 'contributions "未知 kind：~a" (contribution-kind c))))))

  ;; 2. commands
  (for ([(id c) (in-hash commands)])
    (unless (command? c)
      (add! (err 'commands "命令 ~a 不是 command：~a" id c))))

  ;; 3. keymaps（env / mode / doc-type / rule）
  (define keymaps
    (append
     (for/list ([(name km) (in-hash (environment-keymaps env))]) (cons name km))
     (append*
      (for/list ([(id m) (in-hash modes)]) 
        (for/list ([km (in-list (mode-keymaps m))]) (cons id km))))
     (append*
      (for/list ([(id dt) (in-hash (environment-doc-types env))])
        (for/list ([km (in-list (doc-type-keymaps dt))]) (cons id km))))
     (for/list ([r (in-list (environment-rules env))])
       (cons (rule-scope r) (rule-keymap r)))))
  (for ([p (in-list keymaps)])
    (if (keymap? (cdr p))
        (add-all! (check-keymap 'keymaps (cdr p) commands '()))
        (add! (err 'keymaps "~a 的 keymap 不是 keymap：~a" (car p) (cdr p)))))

  ;; 4. rules 的 scope
  (for ([r (in-list (environment-rules env))])
    (unless (scope-known? scopes (rule-scope r))
      (add! (err 'rules "rule scope 未注册：~a" (rule-scope r)))))

  ;; 5. doc-type 的 mode
  (for ([(id dt) (in-hash (environment-doc-types env))])
    (unless (hash-has-key? modes (doc-type-mode dt))
      (add! (err 'doc-types "doc-type ~a 的 mode 未注册：~a" id (doc-type-mode dt)))))

  ;; 6. face-layers：唯一
  (add-all!
   (check-unique-name 'face-layers 'layer (environment-face-layers env)
                      (λ (x) x) '()))
  (for ([l (in-list (environment-face-layers env))])
    (unless (symbol? l)
      (add! (err 'face-layers "face layer 不是 symbol：~a" l))))

  ;; 7. decors：layer 已声明 + 同层唯一 + id 唯一
  (define decor-layers (map face-decor-layer (environment-decors env)))
  (for ([d (in-list (environment-decors env))])
    (unless (memq (face-decor-layer d) (environment-face-layers env))
      (add! (err 'decors "decor ~a 的 layer 未在 face-layers 声明：~a"
                 (face-decor-id d) (face-decor-layer d)))))
  (add-all! (check-unique-name 'decors 'layer decor-layers (λ (x) x) '()))
  (add-all! (check-unique-name 'decors 'id (environment-decors env)
                               face-decor-id '()))

  ;; 8. status parts：名字唯一
  (when (environment-status env)
    (add-all! (check-unique-name 'status 'name (environment-status env)
                                 status-part-name '())))

  ;; 9. input commands：名字唯一
  (add-all! (check-unique-name 'input-commands 'name (environment-input-commands env)
                               input-command-name '()))

  ;; 10. hooks：point / priority 已由 make-hook 保证，这里再检查一遍
  (for ([h (in-list (environment-hooks env))])
    (unless (symbol? (hook-point h))
      (add! (err 'hooks "hook point 不是 symbol：~a" (hook-point h))))
    (unless (exact-integer? (hook-priority h))
      (add! (err 'hooks "hook priority 不是整数：~a" (hook-priority h)))))

  ;; 11. panel-syncs
  (for ([f (in-list (environment-panel-syncs env))])
    (unless (procedure? f)
      (add! (err 'panel-syncs "panel-sync 不是过程：~a" f))))

  ;; 11b. interactions：kind / handler
  (for ([(kind handler) (in-hash (environment-interactions env))])
    (unless (symbol? kind)
      (add! (err 'interactions "interaction kind 不是 symbol：~a" kind)))
    (unless (procedure? handler)
      (add! (err 'interactions "interaction ~a 的 handler 不是过程：~a" kind handler))))

  ;; 11b.2 continuations：tag / handler
  (for ([(tag handler) (in-hash (environment-continuations env))])
    (unless (symbol? tag)
      (add! (err 'continuations "continuation tag 不是 symbol：~a" tag)))
    (unless (procedure? handler)
      (add! (err 'continuations "continuation ~a 的 handler 不是过程：~a" tag handler))))

  ;; 11c. services：kind / description / pure?
  (for ([(kind spec) (in-hash (environment-services env))])
    (unless (symbol? kind)
      (add! (err 'services "service kind 不是 symbol：~a" kind)))
    (unless (service-spec? spec)
      (add! (err 'services "service ~a 不是 service-spec：~a" kind spec)))
    (when (service-spec? spec)
      (unless (eq? (service-spec-kind spec) kind)
        (add! (err 'services "service key ~a 与 spec.kind ~a 不一致"
                   kind (service-spec-kind spec))))
      (unless (boolean? (service-spec-pure? spec))
        (add! (err 'services "service ~a 的 pure? 不是 boolean：~a"
                   kind (service-spec-pure? spec))))))

  ;; 12. panels（从 contributions 里取）：mode / role / sync
  (for ([c (in-list (environment-contributions env))]
        #:when (and (contribution? c) (eq? (contribution-kind c) 'panel)))
    (define p (contribution-payload c))
    (unless (panel-spec? p)
      (add! (err 'panels "panel contribution 的 payload 不是 panel-spec：~a" p)))
    (when (panel-spec? p)
      (unless (hash-has-key? modes (panel-spec-mode p))
        (add! (err 'panels "panel ~a 的 mode 未注册：~a"
                   (panel-spec-name p) (panel-spec-mode p))))
      (unless (hash-has-key? roles (panel-spec-role p))
        (add! (err 'panels "panel ~a 的 role 未注册：~a"
                   (panel-spec-name p) (panel-spec-role p))))
      (unless (or (not (panel-spec-sync p)) (procedure? (panel-spec-sync p)))
        (add! (err 'panels "panel ~a 的 sync 不是过程：~a"
                   (panel-spec-name p) (panel-spec-sync p))))
      (unless (or (not (panel-spec-install p)) (procedure? (panel-spec-install p)))
        (add! (err 'panels "panel ~a 的 install 不是过程：~a"
                   (panel-spec-name p) (panel-spec-install p))))
      (unless (or (not (panel-spec-hint p)) (dim? (panel-spec-hint p)))
        (add! (err 'panels "panel ~a 的 hint 不是 dim：~a"
                   (panel-spec-name p) (panel-spec-hint p))))
      (unless (or (and (not (panel-spec-owner p)) (not (panel-spec-key p)))
                  (and (symbol? (panel-spec-owner p)) (symbol? (panel-spec-key p))))
        (add! (err 'panels "panel ~a 的 owner/key 不合法：~a / ~a"
                   (panel-spec-name p) (panel-spec-owner p) (panel-spec-key p))))
      (unless (memq (panel-spec-placement p) '(active inactive))
        (add! (err 'panels "panel ~a 的 placement 不合法：~a"
                   (panel-spec-name p) (panel-spec-placement p))))))

  out)

(define (validate-environment! env)
  (define es (validate-environment env))
  (unless (null? es)
    (error 'validate-environment
           "环境校验失败：\n~a"
           (string-join
            (for/list ([e (in-list es)])
              (format "  [~a] ~a" (validation-error-where e)
                      (validation-error-message e)))
            "\n")))
  env)

(define (environment-valid? env)
  (null? (validate-environment env)))

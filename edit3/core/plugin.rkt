#lang racket

;;; edit3/plugin.rkt —— 插件契约 + 装配器（edit2 注册表风格）
;;;
;;; 一个 plugin = 一个纯数据包，向 edit3 的各个**注册表**贡献能力；装配器（boot）把这些
;;; 贡献叠加到基础注册表上，得到本次运行实际使用的 op / prompt-kind / panel / region /
;;; key-table / doc-key-matcher，并存进 State 的 feature（step 从 State 读，不依赖插件）。
;;;
;;;   ops              : (listof (cons tag handler))      原语（可在基础表上覆盖）
;;;   prompt-kinds     : (listof (cons kind handler))     输入行语义
;;;   panels           : (listof panel-spec)              面板（按名字覆盖）
;;;   regions          : (listof region)                  区域
;;;   key-tables       : (listof (listof entry))          键表（后表覆盖前表）
;;;   doc-key-matchers : (listof (cons matcher table))    路径 → 文档键表
;;;   boot             : (state -> state) | #f            装配时跑一次（初始化 feature 等）
;;;
;;; 依赖方向：plugin 只依赖 state/op/prompt/panels/keymap 等**基础模块**，不依赖 step；
;;; step 依赖本模块 + catalog（解析启用名单），因此不会循环。

(provide (struct-out plugin) make-plugin
         install-plugin-ops install-plugin-prompts install-plugin-panels
         install-plugin-regions collect-key-tables collect-doc-key-matchers
         collect-hooks collect-faces run-plugin-boots run-plugin-open)

(require racket/list
         "state.rkt" "op.rkt" "prompt.rkt" "panels.rkt" "hook.rkt")

(struct plugin (name ops prompt-kinds panels regions key-tables doc-key-matchers
                faces hooks boot on-open)
  #:transparent)

(define (make-plugin #:name name
                     #:ops [ops '()]
                     #:prompt-kinds [prompt-kinds '()]
                     #:panels [panels '()]
                     #:regions [regions '()]
                     #:key-tables [key-tables '()]
                     #:doc-key-matchers [doc-key-matchers '()]
                     #:faces [faces '()]
                     #:hooks [hooks '()]
                     #:boot [boot #f]
                     #:on-open [on-open #f])
  (plugin name ops prompt-kinds panels regions key-tables doc-key-matchers faces hooks boot on-open))

;;; ---------- 装配 ----------

(define (install-plugin-ops base specs)
  (for/fold ([reg base]) ([p (in-list specs)])
    (for/fold ([r reg]) ([o (in-list (plugin-ops p))])
      (op-register r (car o) (cdr o)))))

(define (install-plugin-prompts base specs)
  (for/fold ([reg base]) ([p (in-list specs)])
    (for/fold ([r reg]) ([k (in-list (plugin-prompt-kinds p))])
      (prompt-kind-register r (car k) (cdr k)))))

(define (install-plugin-panels base specs)
  (for/fold ([reg base]) ([p (in-list specs)])
    (for/fold ([r reg]) ([spec (in-list (plugin-panels p))])
      (panel-register r spec))))

;; 区域：基础在前、插件在后；同名取先出现的（基础）。
(define (install-plugin-regions base specs)
  (append base (append* (for/list ([p (in-list specs)]) (plugin-regions p)))))

(define (collect-key-tables specs)
  (append* (for/list ([p (in-list specs)]) (plugin-key-tables p))))

(define (collect-doc-key-matchers specs)
  (append* (for/list ([p (in-list specs)]) (plugin-doc-key-matchers p))))

(define (collect-hooks specs)
  (append* (for/list ([p (in-list specs)]) (plugin-hooks p))))

(define (collect-faces specs)
  (append* (for/list ([p (in-list specs)]) (plugin-faces p))))

;; 依次跑每个插件的 boot（#f 跳过）。
(define (run-plugin-boots st specs)
  (for/fold ([s st]) ([p (in-list specs)])
    (define f (plugin-boot p))
    (if f (f s) s)))

;; 文档打开（新增或复用）时跑每个插件的 on-open：on-open : state did path -> state。
(define (run-plugin-open st specs did path)
  (for/fold ([s st]) ([p (in-list specs)])
    (define f (plugin-on-open p))
    (if f (f s did path) s)))

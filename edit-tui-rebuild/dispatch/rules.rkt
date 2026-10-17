#lang racket

;;; dispatch/rules.rkt —— 活动命令表的有序规则（纯）
;;;
;;; 一条规则 = scope + keymap。dispatch 按顺序试：
;;;   scope 成立 + keymap 命中（leaf） -> 执行
;;;   scope 成立 + keymap 命中（prefix） -> 继续读键
;;;   其余继续下一条
;;;
;;; 层序（高 -> 低）：
;;;   input.modes（临时模态 / overlay）
;;;   document 自己的 keymap-layers（per-doc 插件覆盖）
;;;   mode 默认 keymaps（原 doc-kind）
;;;   global
;;;
;;; 注意：这里把“层序”集中成一个函数，而不是散在 step-key 的 append 里。
;;; 以后加“插件全局层”只需在 append 里插一段，或把 extra rules 放进 environment。

(provide (all-from-out "../env/rule.rkt")
         rules-for
         subject-mode-id
         prefix-rules
         lookup-rules)

(require "../base/keymap.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/input.rkt"
         "../env/environment.rkt"
         "../env/scope.rkt"
         "../env/rule.rkt")

;;; ---------- 当前 focus / subject 的 mode ----------

(define (subject-doc-meta state subject)
  (define ws (state-workspace state))
  (define did (and subject (workspace-doc-of-view ws subject)))
  (and did (workspace-doc ws did)))

(define (subject-mode-id state subject)
  (define dm (subject-doc-meta state subject))
  (and dm (doc-meta-mode dm)))

;;; ---------- 规则生成 ----------

(define (input-mode-rules env state)
  (for/list ([m (in-list (input-modes (state-input state)))])
    (make-rule 'always (environment-keymap env m))))

(define (doc-layer-rules state subject)
  (define dm (subject-doc-meta state subject))
  (for/list ([km (in-list (if dm (doc-meta-keymap-layers dm) '()))])
    (make-rule 'always km)))

(define (mode-rules env state subject)
  (define mid (subject-mode-id state subject))
  (if mid
      (for/list ([km (in-list (environment-mode-keymaps env mid))])
        (make-rule 'always km))
      '()))

(define (global-rules env)
  (list (make-rule 'always (environment-keymap env 'global))))

;; environment.rules 是插件 / 用户注册的带 scope 层。
(define (extra-rules env state)
  (define scopes (environment-scopes env))
  (for/list ([r (in-list (environment-rules env))]
             #:when (scope-ok? scopes state (rule-scope r)))
    r))

;; 按层序生成，再按 scope 过滤。subject 决定 mode / per-doc 层。
(define (rules-for env state subject)
  (define scopes (environment-scopes env))
  (for/list ([r (in-list
                 (append (input-mode-rules env state)
                         (doc-layer-rules state subject)
                         (extra-rules env state)
                         (mode-rules env state subject)
                         (global-rules env)))]
             #:when (scope-ok? scopes state (rule-scope r)))
    r))

;; 前缀编辑是独立的第一层：pending 非空时先单独查 prefix 表，
;; 未命中再落普通 rules。
(define (prefix-rules env)
  (list (make-rule 'always (environment-keymap env 'prefix))))

;;; ---------- 查表 ----------

;; 在规则列表上查序列：第一个非 unbound 胜出（覆盖语义）。
;; → (values 'leaf value) | (values 'prefix #f) | (values 'unbound #f)
(define (lookup-rules rules seq)
  (for/fold ([status 'unbound] [value #f]) ([r (in-list rules)])
    (if (eq? status 'unbound)
        (keymap-lookup (rule-keymap r) seq)
        (values status value))))

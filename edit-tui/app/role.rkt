#lang racket

;;; app/role.rkt —— leaf「角色」→ 行为 的注册表
;;;
;;; layout 的 leaf 有一个自由符号字段 `role`（默认 'panel）。app **不写死** role 名，
;;; 而是查这张表决定该角色的行为。新增一种区域只需 `define-role!` + `pane #:role`，
;;; 不用改 ops。
;;;
;;; ── 值词汇（role 相关） ──────────────────────────────────────────────
;;;
;;;   role 名        : 任意 symbol（开放集）。内置：
;;;                      'editor  编辑区
;;;                      'panel   固定面板（默认）
;;;                      'slot    固定共享槽（状态栏 / 输入栏；不可隐藏、不可切分）
;;;                    用户可自定义，如 'tool / 'sidebar。
;;;
;;;   splittable?    : #t | #f
;;;                      #t → split-left/right/up/down 作用于该 role 的 leaf
;;;
;;;   close-policy   : 'hide | 'delete | 'keep-last | 'ignore
;;;                      'hide       只隐藏，不删（再显示用 show-pane/toggle-pane）
;;;                      'delete     直接删 leaf
;;;                      'keep-last  删，除非这是**该 role 的最后一块** → 只清 view
;;;                                  （保留空占位，焦点不动）
;;;                      'ignore     什么都不做（固定 chrome，不可关）
;;;
;;;   未注册的 role  → 保守默认：splittable? #f、close-policy 'hide
;;;
;;; ── 用法 ────────────────────────────────────────────────────────────
;;;
;;;   (define-role! 'editor #:splittable? #t #:close 'keep-last)   ; 内置，可覆盖
;;;   (role-of 'editor)              ; → role 结构
;;;   (role-splittable? (role-of r)) ; → bool
;;;   (role-close-policy (role-of r)) ; → 'hide | 'delete | 'keep-last

(provide (struct-out role)
         define-role!
         role-of role-known?)

(struct role (name splittable? close-policy) #:transparent)
;; name         : symbol
;; splittable?  : bool
;; close-policy : 'hide | 'delete | 'keep-last | 'ignore

(define registry (make-hasheq))            ; symbol → role

(define (define-role! name #:splittable? [splittable? #f] #:close [close-policy 'hide])
  (unless (symbol? name) (error 'define-role! "role 名要是 symbol：~a" name))
  (unless (memq close-policy '(hide delete keep-last ignore))
    (error 'define-role! "close 要是 'hide/'delete/'keep-last/'ignore：~a" close-policy))
  (hash-set! registry name (role name splittable? close-policy))
  (void))

;; role 名 → 行为（未注册 = 保守默认）。
(define (role-of name)
  (hash-ref registry name (λ () (role name #f 'hide))))

(define (role-known? name) (and name (hash-has-key? registry name)))

;;; ---------- 内置默认 ----------
(define-role! 'editor #:splittable? #t #:close 'keep-last)
(define-role! 'panel  #:splittable? #f #:close 'hide)
(define-role! 'slot   #:splittable? #f #:close 'ignore)   ; 固定共享槽：不可隐藏

#lang racket

;;; app/role.rkt —— leaf「角色」→ 行为 的注册表
;;;
;;; layout 的 leaf 有一个自由符号字段 `role`（默认 'panel）。app **不写死** role 名，
;;; 而是查这张表决定该角色的行为：能不能被 split、关闭时怎么处理。
;;;
;;;   (define-role! 'editor #:splittable? #t #:close 'keep-last)   ; 编辑区
;;;   (define-role! 'panel  #:splittable? #f #:close 'hide)        ; 固定面板
;;;
;;; 关闭策略 close：
;;;   'hide        只隐藏，不删（固定面板；再显示用 show-pane/toggle-pane）
;;;   'delete      直接删 leaf
;;;   'keep-last   删，除非这是**该 role 的最后一块** → 只清 view（保留空占位）
;;;
;;; 未注册的 role → 保守默认：不 splittable、close='hide'。
;;; 这两个内置默认在模块加载时注册；上层可 `define-role!` 覆盖或新增。

(provide (struct-out role)
         define-role!
         role-config role-known?)

(struct role (name splittable? close) #:transparent)
;; name       : symbol
;; splittable?: bool    split-left/right/up/down 是否作用于该 role 的 leaf
;; close      : 'hide | 'delete | 'keep-last

(define registry (make-hasheq))            ; symbol → role

(define (define-role! name #:splittable? [splittable? #f] #:close [close 'hide])
  (unless (symbol? name) (error 'define-role! "role 名要是 symbol：~a" name))
  (unless (memq close '(hide delete keep-last))
    (error 'define-role! "close 要是 'hide/'delete/'keep-last：~a" close))
  (hash-set! registry name (role name splittable? close))
  (void))

;; role 名 → 行为（未注册 = 保守默认）。
(define (role-config name)
  (hash-ref registry name (λ () (role name #f 'hide))))

(define (role-known? name) (and name (hash-has-key? registry name)))

;;; ---------- 内置默认 ----------
(define-role! 'editor #:splittable? #t #:close 'keep-last)
(define-role! 'panel  #:splittable? #f #:close 'hide)

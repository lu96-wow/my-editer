#lang racket

;;; layer  : env
;;; effect : 无（纯值）
;;;
;;; env/panel-spec.rkt —— 面板描述符（插件贡献 / extension 校验共用）
;;;
;;; 单独成模块，避免 env/plugin.rkt ↔ env/extension.rkt 的循环依赖：
;;;   plugin  -> panel-spec
;;;   extension -> panel-spec
;;;   extension -> environment
;;;   plugin -> extension
;;;
;;; 面板身份 = name / role / mode / sync；安装位置仍由宿主决定。

(provide (struct-out panel-spec)
         make-panel-spec)

(struct panel-spec (name role mode sync) #:transparent)
;; name : string     document 名（资源列表 / 调试里可见）
;; role : symbol     区域角色（splittable? / close-policy / focusable? / target?）
;; mode : symbol     document mode（决定面板内键表）
;; sync : (state engine -> any)  每帧渲染前的同步（挂到 env.panel-syncs）

(define (make-panel-spec #:name [name "*panel*"]
                         #:role [role 'panel]
                         #:mode [mode 'text]
                         #:sync [sync #f])
  (unless (string? name) (error 'make-panel-spec "name 要是 string：~a" name))
  (unless (symbol? role) (error 'make-panel-spec "role 要是 symbol：~a" role))
  (unless (symbol? mode) (error 'make-panel-spec "mode 要是 symbol：~a" mode))
  (unless (or (not sync) (procedure? sync))
    (error 'make-panel-spec "sync 要是过程或 #f：~a" sync))
  (panel-spec name role mode sync))

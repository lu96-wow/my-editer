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
;;; 面板身份 = name / role / mode / sync / install / hint / owner / key / placement；
;;; 安装位置仍由宿主决定。

(provide (struct-out panel-spec)
         make-panel-spec)

(require "../model/layout.rkt")

(struct panel-spec (name role mode sync install hint owner key placement) #:transparent)
;; name : string     document 名（资源列表 / 调试里可见）
;; role : symbol     区域角色（splittable? / close-policy / focusable? / target?）
;; mode : symbol     document mode（决定面板内键表）
;; sync : (state engine -> any)  每帧渲染前的同步（挂到 env.panel-syncs）
;; install : (engine state region-id view-id -> state) | #f
;;           面板创建后的初始化（写插件 store / 展开根目录 / 记 view-id）
;; hint    : #f | dim       布局已有该 region 的 leaf 时，apply 到 leaf.dim
;; owner   : symbol | #f    已安装面板的 owner（plugin id），用于 workspace.panel-index
;; key     : symbol | #f    同一 owner 下的稳定面板 key
;; placement: 'active | 'inactive  加入已存在的多成员 region 时是否设为 active

(define (make-panel-spec #:name [name "*panel*"]
                         #:role [role 'panel]
                         #:mode [mode 'text]
                         #:sync [sync #f]
                         #:install [install #f]
                         #:hint [hint #f]
                         #:owner [owner #f]
                         #:key [key #f]
                         #:placement [placement 'active])
  (unless (string? name) (error 'make-panel-spec "name 要是 string：~a" name))
  (unless (symbol? role) (error 'make-panel-spec "role 要是 symbol：~a" role))
  (unless (symbol? mode) (error 'make-panel-spec "mode 要是 symbol：~a" mode))
  (unless (or (not sync) (procedure? sync))
    (error 'make-panel-spec "sync 要是过程或 #f：~a" sync))
  (unless (or (not install) (procedure? install))
    (error 'make-panel-spec "install 要是过程或 #f：~a" install))
  (unless (or (not hint) (dim? hint))
    (error 'make-panel-spec "hint 要是 dim 或 #f：~a" hint))
  (unless (or (and (not owner) (not key))
              (and (symbol? owner) (symbol? key)))
    (error 'make-panel-spec "owner / key 要么都为 #f，要么都为 symbol：~a / ~a"
           owner key))
  (unless (memq placement '(active inactive))
    (error 'make-panel-spec "placement 要是 active / inactive：~a" placement))
  (panel-spec name role mode sync install hint owner key placement))

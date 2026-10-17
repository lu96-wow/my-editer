#lang racket

;;; app/plugin.rkt —— 插件注册 + 声明式载入
;;;
;;; 用 Racket 的模块机制：插件模块**顶层调用** `define-plugin!` 即注册；
;;; 只要该模块被 `require`，注册就发生 —— require 即生效。
;;;
;;; 启动的“装配阶段”（可造 core 对象，不纯）调 `plugins-apply`，把注册表里的贡献
;;; 折进**当前 world**：
;;;   · 布局贡献：把 `panel-spec` 的 leaf 插进当前 layout（相对锚点切一刀）；
;;;   · 生命周期：跑 `on-load`（初始化插件状态、造面板文档 view）。
;;; 没被 require 的插件不在注册表 → 就没有面板 / 没有状态。
;;;
;;; 与既有注册表的分工：
;;;   · doc-kind / role / 键表：插件顶层照常调各自的 `define-doc-kind!` / `define-role!`；
;;;   · 本模块只管「面板贡献 + 插件状态槽 + 装配」。
;;;
;;; 插件状态存在 `world.ext`（`world-ext-ref` / `world-ext-set`），
;;; 所以 world 仍是纯、可复制、可 headless 重放；不引入全局可变状态。

(require "../layout/main.rkt"
         "world.rkt")

(provide (struct-out plugin)
         (struct-out panel-spec)
         define-plugin!
         plugins-list plugins-known? plugins-reset!
         plugins-apply)

;;; ════════════════════════ 描述符 ════════════════════════

;; 面板贡献：把面板插到当前 layout 的某锚点旁边。
;;   id     : leaf id（默认也是插件名）
;;   side   : 'left | 'right | 'up | 'down     相对锚点
;;   size   : 布局权重（同 tree 的 size；与锚点成比例分配额度）
;;   role   : leaf role（默认 'panel）
;;   anchor : 锚 leaf id | #f（#f = 第一个可见的 'editor leaf）
;; 暂定：这只是「相对锚点切一刀」，不是独立 dock / 分组；固定/夹紧尺寸见尺寸策略（待做）。
(struct panel-spec (id side size role anchor) #:transparent)

;; 插件 = 名字 + 面板贡献 + 生命周期。
;;   on-load   : #f | (world -> world)   装配时跑（可造文档/view、初始化状态）
;;   on-unload : #f | (world -> world)   预留：运行时卸载（暂未接线）
(struct plugin (name panel on-load on-unload) #:transparent)

;;; ════════════════════════ 注册表（模块顶层副作用写入） ════════════════════════

(define registry '())                 ; (listof plugin)，注册顺序

(define (define-plugin! name
                        #:panel [panel #f]
                        #:on-load [on-load #f]
                        #:on-unload [on-unload #f])
  (unless (symbol? name)
    (error 'define-plugin! "插件名要是 symbol：~a" name))
  (set! registry (append registry (list (plugin name panel on-load on-unload))))
  (void))

(define (plugins-list) registry)                         ; 注册（= require）顺序
(define (plugins-known? name)
  (for/or ([p (in-list registry)]) (eq? name (plugin-name p))))
(define (plugins-reset!) (set! registry '()))            ; 测试用

;;; ════════════════════════ 装配（不纯：可造 core 对象 / 读盘） ════════════════════════

;; 把注册表折进 world：逐个插件插面板 + 跑 on-load。幂等：已在布局里的面板不重复插。
(define (plugins-apply w)
  (for/fold ([w w]) ([p (in-list (plugins-list))])
    (define w1 (if (plugin-panel p) (insert-panel w (plugin-panel p)) w))
    (if (plugin-on-load p) ((plugin-on-load p) w1) w1)))

;;; ---------- 布局贡献 ----------

(define (side->axis/side side)
  (case side
    [(left)   (values 'lr 'before)]
    [(right)  (values 'lr 'after)]
    [(up)     (values 'tb 'before)]
    [(down)   (values 'tb 'after)]
    [else (error 'panel-spec "side 要是 left/right/up/down：~a" side)]))

;; 锚点：显式 id（存在才用）或第一个可见 'editor leaf。
(define (resolve-anchor lay anchor)
  (cond
    [anchor (and (tree-contains? lay anchor) anchor)]
    [else (for/first ([l (in-list (tree-visible-leaves lay))]
                      #:when (eq? (leaf-role l) 'editor))
            (leaf-id l))]))

(define (insert-panel w ps)
  (define lay (world-layout w))
  (cond
    [(tree-contains? lay (panel-spec-id ps)) w]          ; 已载入 → 幂等
    [else
     (define anchor (resolve-anchor lay (panel-spec-anchor ps)))
     (if (not anchor)
         w                                               ; 没锚点 → 不插
         (let-values ([(axis side) (side->axis/side (panel-spec-side ps))])
           (define lay* (tree-split lay anchor axis (panel-spec-id ps)
                                    #:side side #:role (panel-spec-role ps)))
           (world-set-layout w (tree-set-dim lay* (panel-spec-id ps)
                                              (panel-spec-size ps)))))]))

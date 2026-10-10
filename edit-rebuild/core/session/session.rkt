#lang racket

;;; edit-rebuild/core/session/session.rkt —— 会话根值（纯）：子值的组合
;;;
;;; 局部问题：会话 = 一层薄薄的根，把相互独立的子值组合起来，并给出跨子值的只读访问
;;; 与纯变换。每个子值自己回答一个局部问题：
;;;
;;;   ed          core editor（文档 / 视图真身）
;;;   layout-state session/layout-state.rkt  骨架 / 洞绑定 / 编辑区子树 / 派生布局
;;;   ui          session/ui-state.rkt       尺寸 / 退出 / 显隐 / 日志
;;;   input       session/input-state.rkt    焦点 / 活动视图 / 前缀 / 输入行
;;;   surface-set session/surfaces.rkt       面登记 + 浮 vid 书签
;;;   docs-state  session/docs-state.rkt     文档域（台账 / 键表 / 插件绑定）
;;;   runtime     session/runtime.rkt        可变运行时（服务 / 异步闸门）
;;;   keys rules handlers hooks              配置注入的命令 / 规则 / 通知
;;;
;;; 本文件不认识 core/editor（那是 session/adapter.rkt 的唯一职责）；ed 由调用方给。

(require "layout-state.rkt"
         "ui-state.rkt"
         "input-state.rkt"
         "surfaces.rkt"
         "docs-state.rkt"
         "runtime.rkt"
         "../focus.rkt"
         "../ids.rkt"
         "../geometry/layout.rkt"
         "../surface/surface.rkt"
         "../doc/catalog.rkt")

(provide
 (struct-out session)
 session-new session-new-blank session-assemble
 ;; 布局
 session-layout session-frame session-bindings session-editor
 session-set-editor session-set-frame session-set-binding
 ;; ui
 session-width session-height session-quit? session-presentations
 session-visible? session-set-visible session-resize session-quit session-log-add
 session-log
 ;; input
 session-focus session-focus-vid session-edit-vid session-prefix session-prompt
 session-set-prefix session-set-prompt session-set-edit-vid
 ;; 面判定（dock / 键表 / 浮动）
 session-dock-vid? session-vid-keys session-float-vid?
 ;; surfaces
 session-surfaces session-overlays
 session-add-surface session-remove-surface session-surface-ref session-surface-for-vid
 ;; docs
 session-doc-catalog session-doc-keymaps session-plugin-bindings
 session-set-doc-catalog session-set-doc-keymap session-set-plugin-bindings session-docs-remove
 session-plugin-bindings-remove
 session-file-path session-file-did session-file-dids session-set-file
 ;; runtime
 session-services session-awaiting session-service-ref session-service-put
 session-await-put session-await-ref session-await-remove
 ;; 配置注入
 session-add-handler session-set-rules session-add-key)

(struct session (ed layout-state ui input surface-set docs-state runtime
                  keys rules handlers hooks)
  #:transparent)
;; ed          : core editor
;; layout-state: layout-state
;; ui          : ui-state
;; input       : input-state
;; surface-set : surfaces
;; docs-state  : docs-state
;; runtime     : runtime
;; keys        : (listof keymap)
;; rules       : (listof rule)
;; handlers    : (listof (session cmd -> (or/c session #f)))
;; hooks       : (listof hook)

(define (session-new ed layout-state ui input surface-set docs-state runtime keys rules handlers hooks)
  (session ed layout-state ui input surface-set docs-state runtime keys rules handlers hooks))

;; 空会话（ed 由 adapter 传入：只有那里 require core/editor）。
(define (session-new-blank ed width height [keys '()])
  (session-new ed
               (layout-state-new #f (hash) (blank))
               (ui-state-new width height)
               (input-state-new (focus-new #f))
               (surfaces-new)
               (docs-state-new)
               (runtime-new)
               keys '() '() '()))

;;; ---------- 布局 ----------

(define (session-assemble s frame bindings)
  (struct-copy session s
    [layout-state (layout-state-new frame bindings (session-editor s))]))

(define (session-layout s) (layout-state-layout (session-layout-state s)))
(define (session-frame s) (layout-state-frame (session-layout-state s)))
(define (session-bindings s) (layout-state-bindings (session-layout-state s)))
(define (session-editor s) (layout-state-editor (session-layout-state s)))
(define (session-set-editor s editor)
  (struct-copy session s [layout-state (layout-state-set-editor (session-layout-state s) editor)]))
(define (session-set-frame s frame)
  (struct-copy session s [layout-state (layout-state-set-frame (session-layout-state s) frame)]))
(define (session-set-binding s slot node)
  (struct-copy session s [layout-state (layout-state-set-binding (session-layout-state s) slot node)]))

;;; ---------- ui ----------

(define (session-width s) (ui-state-width (session-ui s)))
(define (session-height s) (ui-state-height (session-ui s)))
(define (session-quit? s) (ui-state-quit? (session-ui s)))
(define (session-presentations s) (ui-state-presentations (session-ui s)))
(define (session-visible? s vid) (ui-visible? (session-ui s) vid))
(define (session-set-visible s vid on?)
  (struct-copy session s [ui (ui-set-visible (session-ui s) vid on?)]))
(define (session-resize s w h) (struct-copy session s [ui (ui-resize (session-ui s) w h)]))
(define (session-quit s) (struct-copy session s [ui (ui-quit (session-ui s))]))
(define (session-log-add s lines) (struct-copy session s [ui (ui-log-add (session-ui s) lines)]))
(define (session-log s) (ui-state-log (session-ui s)))

;;; ---------- input ----------

(define (session-focus s) (input-state-focus (session-input s)))
(define (session-focus-vid s) (focus-target (session-focus s)))
(define (session-edit-vid s) (input-state-edit-vid (session-input s)))
(define (session-prefix s) (input-state-prefix (session-input s)))
(define (session-prompt s) (input-state-prompt (session-input s)))
(define (session-set-prefix s p)
  (struct-copy session s [input (input-state-set-prefix (session-input s) p)]))

(define (session-set-prompt s p)
  (struct-copy session s [input (struct-copy input-state (session-input s) [prompt p])]))
(define (session-set-edit-vid s vid)
  (struct-copy session s [input (input-state-set-edit-vid (session-input s) vid)]))

;; dock = 面 vid：焦点落到它们时不改变粘性 edit-vid。
(define (session-dock-vid? s vid)
  (and vid (and (session-surface-for-vid s vid) #t)))

;; float = 浮动面 vid（补全 / 文档窗）：不聚焦、不响应鼠标。
(define (session-float-vid? s vid)
  (define sf (and vid (session-surface-for-vid s vid)))
  (and sf (surface-float? sf)))

;; 面自带键表（聚焦时生效）。
(define (session-vid-keys s vid)
  (define sf (session-surface-for-vid s vid))
  (and sf (surface-keys sf)))

;;; ---------- surfaces ----------

(define (session-surfaces s) (surfaces-items (session-surface-set s)))
(define (session-overlays s) (surfaces-floats (session-surface-set s)))
(define (session-add-surface s sf)
  (struct-copy session s [surface-set (surfaces-add (session-surface-set s) sf)]))
(define (session-remove-surface s id)
  (struct-copy session s [surface-set (surfaces-remove (session-surface-set s) id)]))
(define (session-surface-ref s id) (surfaces-ref (session-surface-set s) id))
(define (session-surface-for-vid s vid) (surfaces-for-vid (session-surface-set s) vid))

;;; ---------- docs ----------

(define (session-doc-catalog s) (docs-state-catalog (session-docs-state s)))
(define (session-doc-keymaps s) (docs-state-keymaps (session-docs-state s)))
(define (session-plugin-bindings s) (docs-state-plugin-bindings (session-docs-state s)))
(define (session-set-doc-catalog s catalog)
  (struct-copy session s [docs-state (docs-state-set-catalog (session-docs-state s) catalog)]))
(define (session-set-doc-keymap s did km)
  (struct-copy session s [docs-state (docs-state-set-keymap (session-docs-state s) did km)]))
(define (session-set-plugin-bindings s did ps)
  (struct-copy session s [docs-state (docs-state-set-plugin-bindings (session-docs-state s) did ps)]))
(define (session-docs-remove s did)
  (struct-copy session s [docs-state (docs-state-remove (session-docs-state s) did)]))
(define (session-plugin-bindings-remove s did)
  (struct-copy session s [docs-state (docs-state-remove-plugin-binding (session-docs-state s) did)]))

;; did <-> path（台账在 doc/catalog 的 doc-state 里）
(define (session-file-path s did) (doc-state-path (session-doc-catalog s) did))
(define (session-file-did s path) (doc-state-did (session-doc-catalog s) path))
(define (session-file-dids s) (doc-state-dids (session-doc-catalog s)))
(define (session-set-file s did path)
  (session-set-doc-catalog s (doc-state-set-path (session-doc-catalog s) did path)))

;;; ---------- runtime ----------

(define (session-services s) (runtime-services (session-runtime s)))
(define (session-awaiting s) (runtime-awaiting (session-runtime s)))
(define (session-service-ref s name) (runtime-service-ref (session-runtime s) name))
(define (session-service-put s name v)
  (struct-copy session s [runtime (runtime-service-put (session-runtime s) name v)]))
(define (session-await-put s id e)
  (struct-copy session s [runtime (runtime-await-put (session-runtime s) id e)]))
(define (session-await-ref s id) (runtime-await-ref (session-runtime s) id))
(define (session-await-remove s id)
  (struct-copy session s [runtime (runtime-await-remove (session-runtime s) id)]))

;;; ---------- 配置注入 ----------

(define (session-add-handler s h)
  (struct-copy session s [handlers (cons h (session-handlers s))]))
(define (session-set-rules s rules) (struct-copy session s [rules rules]))
(define (session-add-key s km)
  (struct-copy session s [keys (append (session-keys s) (list km))]))

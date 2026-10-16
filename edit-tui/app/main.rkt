#lang racket

;;; app/main.rkt —— app 骨架入口（事件循环 + 状态 + 原语），全部再导出
;;;
;;; ═══════════════════════════════════════════════════════════════════
;;; 一句话：事件 → 纯 world-step → intent 列表 → loop 解释并重绘。
;;; 行为不写死在流程里，而是「查注册表」判出来的。
;;; ═══════════════════════════════════════════════════════════════════
;;;
;;; ── 数据流 ────────────────────────────────────────────────────────
;;;
;;;   read-event ─┐
;;;               ├─▶ world-step*   纯：world × event → world + intents
;;;   inbox ──────┘        │
;;;                        ├─ update intent  → 在 step 就地折叠（纯）
;;;                        └─ effect intent  → 交给 loop 解释器（唯一不纯）
;;;                                              │
;;;                                         draw-world（world → bytes）
;;;
;;; ── 模块 ──────────────────────────────────────────────────────────
;;;
;;;   world.rkt       world / ctx / drag / mode / app-event + ref 解析助手
;;;   panel-ref.rkt   leaf/float 的稳定身份 + 解析（ref → view/panel）
;;;   role.rkt        leaf role → 行为：splittable? / close-policy
;;;   doc-kind.rkt    document 类型 → 命令表（+ per-buffer 覆盖层）
;;;   base-keys.rkt   小表：edit / motion / pointer / focus
;;;   ops.rkt         操作 layout / focus / document 的命名原语
;;;   resource.rkt    造 document + view（绑类型）
;;;   intent.rkt      效果即数据
;;;   step.rkt        world-step / world-step*
;;;   render.rkt      draw-world
;;;   loop.rkt        run-app（唯一不纯：读事件 / 跑 intent / 重绘）
;;;
;;; ── 值词汇（都是 symbol 值域） ────────────────────────────────────
;;;
;;;   role 名          'editor 'panel …         开放集；见 role.rkt
;;;   close-policy     'hide 'delete 'keep-last
;;;   panel-ref kind   'leaf 'float
;;;   drag kind        'seam 'select …          step 只解释 'seam
;;;   axis             'lr 'tb                  'lr 左右并排 | 'tb 上下堆叠
;;;   side             'before 'after
;;;   dir              'left 'right 'up 'down   （panel-move 另有 'front 'back）
;;;   dock             'left 'right 'top 'bottom 'center/#f
;;;   borders          'up 'down 'left 'right
;;;   mods             'ctrl 'alt 'shift
;;;   mouse action     'press 'release 'move 'scroll
;;;   mouse button     'left 'middle 'right | 'up 'down | #f
;;;   lookup status    'command 'prefix 'unbound
;;;   intent           update edit select scroll spawn post invoke open-doc
;;;   app-event kind   'task-done …             开放；见 world.internal 注册表
;;;
;;; ── 判定点（都在「查表」） ────────────────────────────────────────
;;;
;;;   事件分派   app-event > key > mouse > resize > paste > null
;;;   命令表     subject ref → view→buffer→kind；层序 mode > per-doc > kind > 全局
;;;   鼠标       命中缝优先；否则命中 panel；拖动中按 drag.subject
;;;   role       splittable? / close-policy（role.rkt）
;;;   重绘       world.dirty?（首帧 force?）
;;;   循环       world.running?
;;;
;;; ── 最小用法 ──────────────────────────────────────────────────────
;;;
;;;   (require "../edit-tui/app/main.rkt")
;;;   (define-doc-kind! 'text #:keymaps (list edit-keys motion-keys pointer-keys))
;;;   (define-role! 'editor #:splittable? #t #:close 'keep-last)   ; 内置，可覆盖
;;;   (run-app
;;;     (make-world #:area (rect 0 0 80 24)
;;;                 #:layout (lay 'tb (pane 'tree #:view tv #:dock 'top)
;;;                               (pane 'editor #:view ev #:role 'editor))
;;;                 #:focus (leaf-ref 'editor)
;;;                 #:keytable (make-keytable my-keys focus-keys)))

(require "world.rkt"
         "intent.rkt"
         "panel-ref.rkt"
         "role.rkt"
         "doc-kind.rkt"
         "base-keys.rkt"
         "ops.rkt"
         "resource.rkt"
         "step.rkt"
         "render.rkt"
         "loop.rkt")

(provide (all-from-out "world.rkt"
                       "intent.rkt"
                       "panel-ref.rkt"
                       "role.rkt"
                       "doc-kind.rkt"
                       "base-keys.rkt"
                       "ops.rkt"
                       "resource.rkt"
                       "step.rkt"
                       "render.rkt"
                       "loop.rkt"))

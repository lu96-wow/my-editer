#lang racket

;;; model/state.rkt —— 根 State（纯数据，方案 B）
;;; layer  : model
;;; effect : 无（纯数据 + 纯更新助手）

;;; State 只装：
;;;   window    会话信息（终端尺寸）
;;;   workspace 文档 / 视图 / 区域 / 布局 / 焦点（model/workspace.rkt）
;;;   input     键序列 / 模态 / 手势 / prompt（model/input.rkt）
;;;   chrome    消息 / 日志（model/chrome.rkt）
;;;   confirm   保存确认队列（model/save.rkt）
;;;   runtime   quit? / revision
;;;   ids       单调 id 分配器（document / view / region / job）
;;;   store     插件命名空间：symbol -> 插件自己的纯数据
;;;             （面板切片都在这里：'resources / 'filetree …）
;;;
;;; **不装**：core 的 buffer / view 句柄、渲染 cache、inbox、线程。
;;; 需要读文本 / 光标时通过 engine-view（只读查询）拿；写走 effect。

(provide (struct-out window)
         (struct-out runtime)
         (struct-out state)
         make-window
         make-runtime
         make-state
         state-empty
         state-next-id
         state-set-window state-set-workspace state-set-input
         state-set-chrome state-set-runtime state-set-ids state-set-confirm
         state-set-store
         state-workspace* state-input* state-chrome* state-runtime* state-confirm*
         state-store*
         plugin-state plugin-state-set plugin-state*
         state-mark-quit state-bump-revision
         state-focus state-set-focus
         state-input-active?)

(require "workspace.rkt"
         "input.rkt"
         "chrome.rkt"
         "save.rkt"
         "../base/id.rkt")

;;; ---------- 会话 ----------

(struct window (rows cols) #:transparent)
;; rows / cols : positive integer（0 也表示未知，调用方自行判断）

(define (make-window rows cols) (window rows cols))

;;; ---------- 运行时 ----------

(struct runtime (quit? revision) #:transparent)
;; quit?    : bool
;; revision : integer   每次成功 dispatch 后自增；投影层据此判断是否需要重绘
;;            （替代旧的 world.dirty? 布尔；不参与领域逻辑）

(define (make-runtime #:quit? [quit? #f] #:revision [revision 0])
  (runtime quit? revision))

;;; ---------- 根 State ----------

(struct state (window workspace input chrome runtime ids confirm store) #:transparent)

(define (make-state #:window [window (make-window 24 80)]
                    #:workspace [workspace (workspace-empty)]
                    #:input [input (input-empty)]
                    #:chrome [chrome (chrome-empty)]
                    #:runtime [runtime (make-runtime)]
                    #:ids [ids (make-id-counter)]
                    #:confirm [confirm #f]
                    #:store [store (hash)])
  (state window workspace input chrome runtime ids confirm store))

(define (state-empty) (make-state))

;;; ---------- 纯更新助手 ----------

(define (state-set-window s w)    (struct-copy state s [window w]))
(define (state-set-workspace s w) (struct-copy state s [workspace w]))
(define (state-set-input s i)     (struct-copy state s [input i]))
(define (state-set-chrome s c)    (struct-copy state s [chrome c]))
(define (state-set-runtime s r)   (struct-copy state s [runtime r]))
(define (state-set-ids s ids)     (struct-copy state s [ids ids]))
(define (state-set-confirm s c)   (struct-copy state s [confirm c]))
(define (state-set-store s st)    (struct-copy state s [store st]))

;; 先拿当前切片、改完再放回（命令里常用）。
(define (state-workspace* s f) (state-set-workspace s (f (state-workspace s))))
(define (state-input* s f)     (state-set-input s (f (state-input s))))
(define (state-chrome* s f)    (state-set-chrome s (f (state-chrome s))))
(define (state-runtime* s f)   (state-set-runtime s (f (state-runtime s))))
(define (state-confirm* s f)   (state-set-confirm s (f (state-confirm s))))
(define (state-store* s f)      (state-set-store s (f (state-store s))))

;;; ---------- 插件命名空间 ----------
;;
;;; 插件状态 = store 里的一个槽（键是 plugin-id）。
;;; 框架不认识任何具体插件：读写都通过这两个函数，投影 / 命令只 require 自己的键。
(define (plugin-state s id [default #f])
  (hash-ref (state-store s) id default))
(define (plugin-state-set s id v)
  (state-set-store s (hash-set (state-store s) id v)))
(define (plugin-state* s id f [default #f])
  (plugin-state-set s id (f (plugin-state s id default))))

(define (state-mark-quit s)
  (state-runtime* s (λ (r) (struct-copy runtime r [quit? #t]))))
(define (state-bump-revision s)
  (state-runtime* s (λ (r) (struct-copy runtime r [revision (add1 (runtime-revision r))]))))

;; 纯分配：→ (values id state')。
(define (state-next-id s kind)
  (define-values (i ids*) (id-counter-next (state-ids s) kind))
  (values i (state-set-ids s ids*)))

;;; ---------- 焦点便捷 ----------

(define (state-focus s) (workspace-focus (state-workspace s)))

;; 输入栏是否占用中：chrome slot 的 active 是 input view。
(define (state-input-active? s)
  (define slot (chrome-slot-info (state-chrome s)))
  (and slot
       (equal? (region-active
                (workspace-region (state-workspace s)
                                  (chrome-slot-region slot)))
               (chrome-slot-input-view slot))))
(define (state-set-focus s vid)
  (state-workspace* s (λ (w) (workspace-set-focus w vid))))

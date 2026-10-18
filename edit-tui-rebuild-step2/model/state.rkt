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
;;;   signals   待处理的信号队列（base/signal.rkt），由 dispatch/hooks.rkt 排空
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
         state-set-store state-set-signals state-set-interactions
         state-emit state-drain-signals
         state-workspace* state-input* state-chrome* state-runtime* state-confirm*
         state-store* state-interactions* 
         state-interaction-top state-interaction-push state-interaction-pop-id state-interaction-pop-kind
         plugin-state plugin-state-set plugin-state* plugin-state-clear
         state-mark-quit state-bump-revision
         state-focus state-set-focus
         state-input-active?)

(require "../base/signal.rkt"
         "workspace.rkt"
         "input.rkt"
         "chrome.rkt"
         "save.rkt"
         "interaction.rkt"
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

(struct state (window workspace input chrome runtime ids confirm signals store interactions) #:transparent)

(define (make-state #:window [window (make-window 24 80)]
                    #:workspace [workspace (workspace-empty)]
                    #:input [input (input-empty)]
                    #:chrome [chrome (chrome-empty)]
                    #:runtime [runtime (make-runtime)]
                    #:ids [ids (make-id-counter)]
                    #:confirm [confirm #f]
                    #:signals [signals (signals-empty)]
                    #:store [store (hash)]
                    #:interactions [interactions '()])
  (state window workspace input chrome runtime ids confirm signals store interactions))

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
(define (state-set-signals s sig) (struct-copy state s [signals sig]))
(define (state-set-interactions s is) (struct-copy state s [interactions is]))

;; 先拿当前切片、改完再放回（命令里常用）。
(define (state-workspace* s f) (state-set-workspace s (f (state-workspace s))))
(define (state-input* s f)     (state-set-input s (f (state-input s))))
(define (state-chrome* s f)    (state-set-chrome s (f (state-chrome s))))
(define (state-runtime* s f)   (state-set-runtime s (f (state-runtime s))))
(define (state-confirm* s f)   (state-set-confirm s (f (state-confirm s))))
(define (state-store* s f)      (state-set-store s (f (state-store s))))
(define (state-interactions* s f) (state-set-interactions s (f (state-interactions s))))

;;; ---------- 交互栈 ----------

(define (state-interaction-top s)
  (and (pair? (state-interactions s)) (car (state-interactions s))))

(define (state-interaction-push s i)
  (state-set-interactions s (cons i (state-interactions s))))

(define (state-interaction-pop-id s id)
  (state-set-interactions
   s (for/list ([x (in-list (state-interactions s))] #:unless (eq? (interaction-id x) id)) x)))

(define (state-interaction-pop-kind s kind)
  (state-set-interactions
   s (for/list ([x (in-list (state-interactions s))] #:unless (eq? (interaction-kind x) kind)) x)))

;;; ---------- 信号 ----------

;; 发一个信号（追加到队列尾部，FIFO）。
(define (state-emit s point args)
  (state-set-signals s (signals-add (state-signals s) (make-signal point args))))

;; 取走全部信号：返回 (values state' (listof signal))，队列清空。
(define (state-drain-signals s)
  (define-values (sigs* queue*) (signals-take (state-signals s)))
  (values (state-set-signals s sigs*) queue*))

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
;; 清掉一个插件的命名空间（卸载用）。
(define (plugin-state-clear s id)
  (state-set-store s (hash-remove (state-store s) id)))

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

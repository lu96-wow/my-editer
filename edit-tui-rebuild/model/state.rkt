#lang racket

;;; model/state.rkt —— 根 State（纯数据，方案 B）
;;;
;;; State 只装：
;;;   window    会话信息（终端尺寸）
;;;   workspace 文档 / 视图 / 区域 / 布局 / 焦点（model/workspace.rkt）
;;;   input     键序列 / 模态 / 手势 / prompt（model/input.rkt）
;;;   chrome    消息 / 日志（model/chrome.rkt）
;;;   runtime   quit? / revision
;;;   ids       单调 id 分配器（document / view / region / job）
;;;
;;; **不装**：core 的 buffer / view 句柄、渲染 cache、inbox、线程。
;;; 需要读文本 / 光标时通过 engine-view（只读查询）拿；写走 effect。

(provide (struct-out window)
         (struct-out runtime)
         (struct-out state)
         (struct-out resources)
         make-window
         make-runtime
         make-state
         state-empty
         state-next-id
         state-set-window state-set-workspace state-set-input
         state-set-chrome state-set-runtime state-set-ids state-set-resources
         state-workspace* state-input* state-chrome* state-runtime* state-resources*
         state-mark-quit state-bump-revision
         state-focus state-set-focus)

(require "workspace.rkt"
         "input.rkt"
         "chrome.rkt"
         "resources.rkt"
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

(struct state (window workspace input chrome runtime ids resources) #:transparent)

(define (make-state #:window [window (make-window 24 80)]
                    #:workspace [workspace (workspace-empty)]
                    #:input [input (input-empty)]
                    #:chrome [chrome (chrome-empty)]
                    #:runtime [runtime (make-runtime)]
                    #:ids [ids (make-id-counter)]
                    #:resources [resources (resources-empty)])
  (state window workspace input chrome runtime ids resources))

(define (state-empty) (make-state))

;;; ---------- 纯更新助手 ----------

(define (state-set-window s w)    (struct-copy state s [window w]))
(define (state-set-workspace s w) (struct-copy state s [workspace w]))
(define (state-set-input s i)     (struct-copy state s [input i]))
(define (state-set-chrome s c)    (struct-copy state s [chrome c]))
(define (state-set-runtime s r)   (struct-copy state s [runtime r]))
(define (state-set-ids s ids)     (struct-copy state s [ids ids]))
(define (state-set-resources s r) (struct-copy state s [resources r]))

;; 先拿当前切片、改完再放回（命令里常用）。
(define (state-workspace* s f) (state-set-workspace s (f (state-workspace s))))
(define (state-input* s f)     (state-set-input s (f (state-input s))))
(define (state-chrome* s f)    (state-set-chrome s (f (state-chrome s))))
(define (state-runtime* s f)   (state-set-runtime s (f (state-runtime s))))
(define (state-resources* s f) (state-set-resources s (f (state-resources s))))

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
(define (state-set-focus s vid)
  (state-workspace* s (λ (w) (workspace-set-focus w vid))))

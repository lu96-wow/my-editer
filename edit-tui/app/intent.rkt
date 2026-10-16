#lang racket

;;; app/intent.rkt —— 效果即数据（纯，无依赖）
;;;
;;; 整个 app 骨架的核心约定：
;;;
;;;     world-step : world × event → (values world' (listof intent))
;;;
;;; world-step 是**纯函数**：它只产出 intent，绝不执行。于是「布局 / 焦点 /
;;; 命令路由 / 拖拽状态」全在一套 world → world 的纯变换里，不纯只集中在
;;; app/loop.rkt 一个文件（解释器）。
;;;
;;; intent 分两类：
;;;
;;;   · 状态意图 update  —— f : world → world，由 step 就地折叠（仍是纯的）。
;;;   · 效果意图         —— edit / select / scroll / spawn / post / run，
;;;                         交给 loop 的解释器执行（唯一不纯的地方）。
;;;
;;; 暂定：命令 run 的约定是 (λ (ctx) (listof intent))。旧式 0 参过程（直接改 core）
;;; 不再直接支持，需要包成 intent（见 README「迁 migration」）。

(provide (struct-out update)
         (struct-out edit)
         (struct-out select)
         (struct-out scroll)
         (struct-out spawn)
         (struct-out post)
         (struct-out invoke)
         (struct-out open-doc)
         modify modify/silent
         intent? state-intent? effect?
         intent-kind)

;; 命名注意：core/editor 已导出 change（版本变更值）与 run（合成值），
;; 所以这里的状态意图构造糖叫 modify，效果意图叫 invoke，避免 require 冲突。

;;; ════════════════════════ 状态意图（纯） ════════════════════════

(struct update (f dirty?) #:transparent)
;; f      : world -> world
;; dirty? : bool   应用后是否标记需要重绘

;; 构造糖：modify = 改状态且要重绘；modify/silent = 改状态但不重绘。
;; 暂定：把「dirty」放在状态意图上，是为了让 step 仍能单方面决定是否重绘；
;; 若以后脏标记逻辑变复杂，可换成命名的 world 字段 + 比较。
(define (modify f) (update f #t))
(define (modify/silent f) (update f #f))

;;; ════════════════════════ 效果意图（不纯） ════════════════════════

(struct edit   (view op)   #:transparent)   ; buffer-edit!（编辑器文本算子）
(struct select (view sel)  #:transparent)   ; view-set-selections!
(struct scroll (view delta)#:transparent)   ; view-scroll!
(struct spawn  (id thunk)  #:transparent)   ; 另起线程；完成后 post (app-event 'task-done (list id v))
(struct post   (ev)        #:transparent)   ; 回投内部事件（异步 / 外部源）
(struct invoke (thunk)     #:transparent)   ; 逃生舱：暂定，给 core 里没有专用 intent 的操作
(struct open-doc (make f)  #:transparent)   ; 开 document+view：不纯创建 + 纯 world 变换
;; make : (-> (values buffer view))        解释器里执行（造 core 对象）
;; f    : (world buffer view -> world)     纯：把新 view 装进布局 / 切焦点

(define (state-intent? x) (update? x))
(define (effect? x)
  (or (edit? x) (select? x) (scroll? x) (spawn? x) (post? x) (invoke? x) (open-doc? x)))
(define (intent? x) (or (state-intent? x) (effect? x)))

;; 调试 / 测试用：intent 的分类符号（不改语义）。
(define (intent-kind i)
  (cond [(update? i) 'update]
        [(edit? i)   'edit]
        [(select? i) 'select]
        [(scroll? i) 'scroll]
        [(spawn? i)  'spawn]
        [(post? i)   'post]
        [(invoke? i) 'invoke]
        [(open-doc? i) 'open-doc]
        [else        'unknown]))

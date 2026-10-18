#lang racket

;;; env/hook.rkt —— 钩子（纯值）：信号点 + 谓词 + 优先级 + 处理过程
;;;
;;; layer  : env
;;; effect : 无（纯值；处理过程返回 transition）
;;;
;;; 一条 hook：
;;;
;;;   point    : 信号点（见 base/signal.rkt 的词表）
;;;   when     : (state engine-view args -> boolean)   只在该次信号上跑
;;;   priority : 大者先跑（同优先级保持注册顺序）
;;;   proc     : (state engine-view args -> transition)
;;;              engine-view 的类型来自 effects/engine.rkt；env 层不依赖它，
;;;              所以这里只写约定，不加 require（跑到时自然拿到 engine-view 值）。
;;;
;;; proc 拿到 engine-view 是**只读**的（和命令一样）：想改文本要发 effect，
;;; 想改状态就直接返回新 state。所以 hook 链整体是纯的，可以 headless 重放。
;;;
;;; 为什么需要它：命令只描述“这次按键做了什么”，而“文本改了之后要重新上色 /
;;; 重新算补全候选 / 刷新文档面板”属于**旁观者**逻辑。把它们写成 hook 值，
;;; 插件就只贡献数据，dispatch / runtime 不需要认识任何具体功能。

(provide (struct-out hook)
         make-hook)

(require "../base/transition.rkt")

(struct hook (point when priority proc) #:transparent)
;; point    : symbol
;; when     : (state engine-view args -> boolean)
;; priority : integer
;; proc     : (state engine-view args -> transition)

(define (make-hook point proc
                   #:when [when (λ (_s _ev _args) #t)]
                   #:priority [priority 0])
  (unless (symbol? point) (error 'make-hook "point 要是 symbol：~a" point))
  (unless (procedure? proc) (error 'make-hook "proc 要是过程：~a" proc))
  (unless (procedure? when) (error 'make-hook "when 要是过程：~a" when))
  (unless (exact-integer? priority) (error 'make-hook "priority 要是整数：~a" priority))
  (hook point when priority proc))

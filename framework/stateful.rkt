#lang racket

(require "../core/text/buffer.rkt" "../core/text/patch.rkt" rackunit)

;;; stateful.rkt —— 有状态插件（F 类：fold + view）
;;;
;;; 与 M 类（buffer → patch，可并行/可丢）不同，F 类维护一个**累计状态**：
;;;   State 是 edit-desc 流上的 left-fold，按序消费、不可跳步、不可丢。
;;;   只有「投影」view(State) 是可丢、可重算的（渲染图）。
;;;
;;; 典型例子：LSP / 增量索引 / 符号表——内部状态必须按序吃进每一次编辑。

(provide
 (struct-out stateful-plugin)
 (struct-out stateful-instance)
 stateful-start
 stateful-feed
 stateful-view)

;; init : (-> buffer State)                 启用时从全量 buffer 建初始状态
;; step : (-> State edit-desc State)        按序消费一次编辑（不可跳）
;; view : (-> State (listof patch))         投影成标注（可丢、可重算）
(struct stateful-plugin (init step view) #:transparent)

;; 运行实例：sp + 当前 state + 已消费的编辑数 rev（供将来版本标记/滞后判定）。
(struct stateful-instance (sp state rev) #:transparent)

(define (stateful-start sp b)
  (stateful-instance sp ((stateful-plugin-init sp) b) 0))

(define (stateful-feed inst desc)
  (struct-copy stateful-instance inst
    [state ((stateful-plugin-step (stateful-instance-sp inst))
            (stateful-instance-state inst) desc)]
    [rev (add1 (stateful-instance-rev inst))]))

(define (stateful-view inst)
  ((stateful-plugin-view (stateful-instance-sp inst))
   (stateful-instance-state inst)))

(module+ test
  ;; 一个计数插件：状态 = 已消费的编辑数（坐标无关，避免 demo 里的位置维护）
  (define counter
    (stateful-plugin
     (lambda (b) 0)                          ; init：从全量 buffer 建状态（这里不需要内容）
     (lambda (n d) (add1 n))                 ; step：每吃一个 edit-desc 计数 +1
     (lambda (n) (if (zero? n)
                     '()
                     (list (patch 'edited 0 0 (list (list 0 0 1 'edited))))))))

  (define inst0 (stateful-start counter (buffer-open "abc")))
  (check-equal? (stateful-instance-rev inst0) 0)
  (check-equal? (stateful-view inst0) '())    ; 0 次编辑 → 无投影

  (define d1 (edit-desc 0 0 0 0 "X"))
  (define inst1 (stateful-feed inst0 d1))
  (define inst2 (stateful-feed inst1 (edit-desc 0 1 0 1 "Y")))
  (check-equal? (stateful-instance-rev inst2) 2)
  (check-equal? (stateful-instance-state inst2) 2)   ; 状态累计
  (check-equal? (stateful-view inst2)
                (list (patch 'edited 0 0 (list (list 0 0 1 'edited)))))  ; 投影可重算

  (displayln "stateful.rkt: all tests passed"))

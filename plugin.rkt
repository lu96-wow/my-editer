#lang racket

(require "buffer.rkt" rackunit)

;;; plugin.rkt —— 函数式插件系统：组合层
;;;
;;; 插件 = (-> buffer buffer) 的纯函数，约定：
;;;   - (buffer-dirty b) 描述「自上次 clean 以来累积的变化行范围」
;;;   - 插件通过 buffer-* 读写全部核心结构（content / markers / properties / overlays）
;;;   - 触到 dirty 之外的行时，用 buffer-mark-dirty 扩大重渲染范围
;;;   - 返回新 buffer；插件自身无副作用（常量数据用闭包捕获）
;;;
;;; 本文件只提供组合机制，不实现任何具体插件。

(provide
 run-plugins
 compose-plugins
 with-plugins)

;;; ---------- 组合 ----------

;; 按列表顺序执行插件：前一个插件的输出是后一个的输入。
(define (run-plugins b plugins)
  (for/fold ([b b]) ([p (in-list plugins)])
    (p b)))

;; 把多个插件合成一个插件。
(define (compose-plugins . plugins)
  (lambda (b) (run-plugins b plugins)))

;; 把插件列表织进一个编辑原语，得到新的编辑函数。
;; edit-fn 形如 (lambda (b . args) new-buffer)，例如 buffer-insert / buffer-newline。
(define (with-plugins plugins edit-fn)
  (lambda (b . args)
    (run-plugins (apply edit-fn b args) plugins)))

;;; ---------- 测试 ----------

(module+ test
  (define b0 (buffer-open "hello\nworld"))

  ;; 空插件列表：原样返回（eq?）
  (check-eq? b0 (run-plugins b0 '()))

  ;; 按顺序执行：后一个插件覆盖前一个对同一 key 的写入
  (define (tag tag-val)
    (lambda (b) (buffer-put-text-property b 0 0 1 'order tag-val)))
  (define b1 (run-plugins b0 (list (tag 'a) (tag 'b))))
  (check-equal? (buffer-get-text-property b1 0 0 'order) 'b)

  ;; compose-plugins 与 run-plugins 等价
  (define both (compose-plugins (tag 'x) (tag 'y)))
  (check-equal? (buffer-get-text-property (both b0) 0 0 'order) 'y)

  ;; mark-dirty：独立扩大重渲染范围
  (define b2 (buffer-mark-dirty b0 1 1))
  (check-equal? (buffer-dirty b2) (dirty-desc 1 1 2 2))

  ;; with-plugins：编辑之后插件运行，且 dirty 保留给渲染层
  (define (dirty-widener b) (buffer-mark-dirty b 0 0))
  (define insert* (with-plugins (list dirty-widener) buffer-insert))
  (define b3 (insert* b0 #\X))
  (check-equal? (buffer->string b3) "Xhello\nworld")
  (check-equal? (buffer-dirty b3) (dirty-desc 0 0 2 2))

  (displayln "plugin.rkt: all tests passed"))

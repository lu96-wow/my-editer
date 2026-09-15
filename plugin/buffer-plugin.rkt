#lang racket

(require "../core/text/buffer.rkt" rackunit)

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
 run-plugins-init
 compose-plugins
 with-plugins)

;;; ---------- 组合 ----------

;; 按列表顺序执行插件：前一个插件的输出是后一个的输入。
;; 插件是 dirty 的唯一消费者：跑完清空 dirty。空列表时原样返回（eq?）。
(define (run-plugins b plugins)
  (if (null? plugins)
      b
      (buffer-clean
       (for/fold ([b b]) ([p (in-list plugins)])
         (p b)))))

;; 首次挂载插件：把整个 buffer 标成 dirty 再跑一遍（初始化全量扫描），
;; 跑完 dirty 被清空。无插件时原样返回。
(define (run-plugins-init b plugins)
  (if (null? plugins)
      b
      (run-plugins (buffer-mark-dirty-all b) plugins)))

;; 把多个插件合成一个插件。
(define (compose-plugins . plugins)
  (lambda (b) (run-plugins b plugins)))

;; 把插件列表织进一个编辑原语，得到新的编辑函数。
;; edit-fn 形如 (lambda (b . args) (values new-buffer desc))，例如 buffer-insert。
;; 返回值同样透传 desc：(values new-buffer desc)。
(define (with-plugins plugins edit-fn)
  (lambda (b . args)
    (define-values (b1 desc) (apply edit-fn b args))
    (values (run-plugins b1 plugins) desc)))

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

  ;; with-plugins：编辑之后插件运行，且 dirty 被插件消费（清空），desc 透传
  (define (dirty-widener b) (buffer-mark-dirty b 0 0))
  (define insert* (with-plugins (list dirty-widener) buffer-insert))
  (define-values (b3 d3) (insert* b0 0 0 #\X))
  (check-equal? (buffer->string b3) "Xhello\nworld")
  (check-false (buffer-dirty b3))
  (check-equal? d3 (edit-desc 0 0 0 0 "X"))

  ;; run-plugins-init：首次全量扫描（dirty 覆盖全部行）
  (define (mark-dirty-lines b)
    (define d (buffer-dirty b))
    (if (not d) b
        (for/fold ([b b])
                  ([line (in-range (dirty-desc-first-line d)
                                   (add1 (dirty-desc-last-line d)))])
          (buffer-put-text-property b line 0 1 'scanned #t))))
  (define b-init (run-plugins-init (buffer-open "a\nb\nc") (list mark-dirty-lines)))
  (check-equal? (buffer-get-text-property b-init 0 0 'scanned) #t)
  (check-equal? (buffer-get-text-property b-init 1 0 'scanned) #t)
  (check-equal? (buffer-get-text-property b-init 2 0 'scanned) #t)
  (check-false (buffer-dirty b-init))

  (displayln "plugin.rkt: all tests passed"))

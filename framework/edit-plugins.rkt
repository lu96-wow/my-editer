#lang racket

(require "../core/text/buffer.rkt" "../core/text/cursor.rkt"
         "../core/text/edit.rkt"
         "deps.rkt" rackunit)

;;; edit-plugins.rkt —— 编辑插件调度（与 plugin-dag 对称，但输出是「编辑」）
;;;
;;; 编辑插件只有一种：buffer (or/c #f edit-desc) -> (listof edit-desc)
;;;   - edit-fn 是纯函数（闭包可带内部状态 = stateful，不是类型）
;;;   - trigger = 触发本次运行的编辑 desc（自动运行时非 #f；命令触发全量时为 #f）
;;;   - 输出 edit-desc（改 content → 产生 dirty），与标注插件（输出 patch）正交
;;;
;;; 线程模型（与标注插件同构）：
;;;   - 按依赖分层；同层独立节点可 'parallel（future）——各自在「同一个只读 buffer」
;;;     上算出编辑，再统一串行应用；'sync 内联。
;;;   - 应用永远是串行的（编辑改坐标），且要求同层节点编辑区不相交（重叠报错）。
;;;   - 'parallel 要求插件纯（不写共享可变 box）；带状态的闭包用 'sync。

(provide
 (struct-out edit-plugin-spec)
 run-edit-plugins
 run-edit-plugins-init)

(struct edit-plugin-spec (name edit-fn deps mode) #:transparent)
;; edit-fn : buffer (or/c #f edit-desc) -> (listof edit-desc)
;; deps    : (listof name)   非空=串行链；空=独立可并行
;; mode    : 'sync | 'parallel

(define (run-edit-plugins b trigger specs)
  (if (null? specs)
      (values b '())
      (begin
        (for ([s (in-list specs)])
          (unless (memq (edit-plugin-spec-mode s) '(sync parallel))
            (error 'run-edit-plugins
                   "plugin ~a: 非法 mode ~a（允许 'sync | 'parallel）"
                   (edit-plugin-spec-name s) (edit-plugin-spec-mode s))))
        (for/fold ([b b] [all-descs '()])
                  ([lvl (in-list (compute-levels specs
                                                 edit-plugin-spec-name
                                                 edit-plugin-spec-deps))]
                   #:when (pair? lvl))
          ;; 同层独立：并行「计算」编辑（同一个只读 b），再统一串行应用
          (define parallel (filter (lambda (s) (eq? (edit-plugin-spec-mode s) 'parallel)) lvl))
          (define sync     (filter (lambda (s) (eq? (edit-plugin-spec-mode s) 'sync))     lvl))
          (define pfs (for/list ([s (in-list parallel)])
                        (future (lambda () ((edit-plugin-spec-edit-fn s) b trigger)))))
          (define edits
            (apply append
                   (append (for/list ([s (in-list sync)])
                             ((edit-plugin-spec-edit-fn s) b trigger))
                           (map touch pfs))))
          (define-values (b2 descs) (buffer-apply-edits b edits))
          (values b2 (append all-descs descs))))))

;; 全量/命令触发：trigger = #f（例如 format / LSP 整文件编辑）
(define (run-edit-plugins-init b specs)
  (run-edit-plugins b #f specs))

(module+ test
  (define b0 (buffer-open "abc\ndef"))

  ;; 单插件：把每行行首插入一个 X（全量，trigger=#f）
  (define (mark-bos b _trigger)
    (list (edit-desc 0 0 0 0 "X")
          (edit-desc 1 0 1 0 "X")))
  (define-values (b1 _d1)
    (run-edit-plugins b0 #f (list (edit-plugin-spec 'm mark-bos '() 'sync))))
  (check-equal? (buffer->string b1) "Xabc\nXdef")

  ;; trigger 感知：只在「插入换行」时补缩进
  (define (indent b trigger)
    (if (and trigger (string-contains? (edit-desc-new-text trigger) "\n"))
        (list (edit-desc 1 0 1 0 "  "))
        '()))
  (define-values (b2 _d2)
    (run-edit-plugins b0 (edit-desc 0 1 0 1 "\n")
                      (list (edit-plugin-spec 'i indent '() 'sync))))
  (check-equal? (buffer->string b2) "abc\n  def")

  ;; 空 specs → 原样
  (define-values (be de) (run-edit-plugins b0 #f '()))
  (check-eq? be b0)
  (check-equal? de '())

  ;; 依赖环 → 报错
  (check-exn exn:fail?
             (lambda ()
               (run-edit-plugins b0 #f
                 (list (edit-plugin-spec 'a mark-bos '(b) 'sync)
                       (edit-plugin-spec 'b mark-bos '(a) 'sync)))))

  ;; 非法 mode → 报错
  (check-exn exn:fail?
             (lambda ()
               (run-edit-plugins b0 #f
                 (list (edit-plugin-spec 'x mark-bos '() 'async)))))

  (displayln "edit-plugins.rkt: all tests passed"))

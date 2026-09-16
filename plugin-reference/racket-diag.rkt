#lang racket

;;; racket-diag.rkt —— 示例标注插件：Racket 诊断（把语言服务器结果桥到 patch）
;;;
;;; 这是文档标注插件（slot #3）：buffer → (listof patch)。
;;; 数据流：buffer 全文 → langserver/analysis 的 module-diagnostics
;;;        → patch（key='diag，value=severity 脸 'error|'warning）→ 渲染下划线。
;;;
;;; 只对「看起来像 Racket 源码」的 buffer 诊断（以 #lang 或 (module 开头），
;;; 否则清空旧诊断（demo 的示例文本不是 Racket，不会误报）。
;;;
;;; 已知限制：module-diagnostics 用 eval（展开+实例化），全文件重算；真实使用
;;; 应改子进程异步 + 去抖，避免每敲一键都跑一次 eval。

(require racket/string
         "../plugin/annotate-api.rkt"
         "../langserver/analysis.rkt")

(provide racket-diag)

(define (racket-diag b)
  (define d (buffer-dirty b))
  (if (not d)
      '()
      (let* ([src (buffer->string b)]
             [n   (buffer-line-count b)]
             [segs (if (racket-source? src)
                       (diagnostics->segs (module-diagnostics src) b)
                       '())])
        (list (patch 'diag 0 (sub1 n) segs)))))

(define (racket-source? src)
  (or (string-prefix? src "#lang")
      (string-prefix? src "(module ")))

;; 诊断 → 单行 segs（(list line start end face)）；跨行诊断简化为标到起始行行尾
(define (diagnostics->segs diags b)
  (for/list ([dg (in-list diags)])
    (define l  (diagnostic-line dg))
    (define c  (diagnostic-col dg))
    (define el (diagnostic-end-line dg))
    (define ec (diagnostic-end-col dg))
    (define end (if (= l el) ec (string-length (buffer-line-ref b l))))
    (list l c end (diagnostic-severity dg))))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit "../core/text/buffer.rkt" "../core/text/patch.rkt")

  ;; 有语法错误 → 产出 key='diag 的 patch，错误行被标 'error
  (define b0 (buffer-mark-dirty-all (buffer-open "(module t racket/base\n  (define x)\n)\n")))
  (define patches (racket-diag b0))
  (check-equal? (length patches) 1)
  (match-define (patch 'diag 0 _n segs) (car patches))
  (check-true (pair? segs))
  (define seg0 (car segs))
  (define l (list-ref seg0 0))
  (define c (list-ref seg0 1))
  (check-equal? l 1)                       ; 错误在第 1 行（0-based）
  (check-equal? (list-ref seg0 3) 'error)

  ;; 应用 patch 后，错误范围内能读到 'diag 属性
  (define b1 (buffer-apply-patches b0 patches))
  (check-equal? (buffer-get-text-property b1 l c 'diag) 'error)

  ;; 非 Racket 源码 → 清空诊断（不误报）
  (define b2 (buffer-mark-dirty-all (buffer-open "你好 hello 世界\nnot racket")))
  (define p2 (racket-diag b2))
  (match-define (patch 'diag 0 _n2 segs2) (car p2))
  (check-equal? segs2 '())

  (displayln "racket-diag.rkt: all tests passed"))

#lang racket

(require racket/file
         "../core/editor.rkt"
         "../core/text/document.rkt")

;;; workspace.rkt —— 文档管理：文件路径 ↔ editor 文档
;;;
;;; editor 的 document-entry 只有 name，不存 path；这个映射放这里。
;;; 它管的是「文档的生命周期」，与文件树无关：
;;;   打开   读文件 → editor-add-document（**只建文档，不建视图**）；已开则复用
;;;   保存   把当前文档写回路径；记录「已保存文本」
;;;   脏？   当前文本 ≠ 已保存文本
;;;   关闭   editor-close-document + 清映射
;;;   查询   已开？/ did → path / 所有已开 path
;;;
;;; **不建视图、不管布局 / 焦点 / 渲染** —— 显示在哪是 app / host 的事。
;;; 于是「打开文件」和「怎么显示」解耦：换标签页 / 单格替换都行。

(provide
 (struct-out ws)
 ws-empty
 ws-open ws-close ws-save ws-dirty?
 ws-did ws-path ws-open? ws-open-paths)

;; by-path : hash（path → did）；用 equal?（path 键）
;; saved   : hash（did → string）最近一次读 / 写时的文档文本（`#f` 表示无路径的 scratch，不入表）
(struct ws (by-path saved) #:transparent)

(define (ws-empty) (ws (hash) (hash)))

(define (ws-did w path) (hash-ref (ws-by-path w) path #f))
(define (ws-open? w path) (and (ws-did w path) #t))
(define (ws-open-paths w) (hash-keys (ws-by-path w)))

(define (ws-path w did)
  (for/first ([(p d) (in-hash (ws-by-path w))] #:when (= did d)) p))

;; 打开：已开则复用；否则读文件 + 建文档。→ (values ws editor did)
(define (ws-open w ed path)
  (define existing (ws-did w path))
  (cond
    [existing (values w ed existing)]
    [else
     (define text (file->string path))
     (define-values (ed* did)
       (editor-add-document ed text (path->string (file-name-from-path path))))
     (values (struct-copy ws w
               [by-path (hash-set (ws-by-path w) path did)]
               [saved (hash-set (ws-saved w) did text)])
             ed* did)]))

;; 关文档。→ (values ws editor)
(define (ws-close w ed did)
  (values (struct-copy ws w
            [by-path (for/hash ([(p d) (in-hash (ws-by-path w))] #:unless (= d did)) (values p d))]
            [saved (hash-remove (ws-saved w) did)])
          (editor-close-document ed did)))

;; 当前文本（从 live 文档取）。
(define (ws-doc-text ed did)
  (document->string (document-entry-document (editor-document-entry ed did))))

;; 有未保存修改？scratch（无 saved）→ #f。
(define (ws-dirty? w ed did)
  (define saved (hash-ref (ws-saved w) did #f))
  (and saved (not (equal? saved (ws-doc-text ed did)))))

;; 写回路径并记录已保存文本。→ (values ws path | #f)
(define (ws-save w ed did)
  (define path (ws-path w did))
  (cond
    [(not path) (values w #f)]
    [else
     (define text (ws-doc-text ed did))
     (display-to-file text path #:exists 'replace)
     (values (struct-copy ws w [saved (hash-set (ws-saved w) did text)]) path)]))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit racket/file "../core/text/document.rkt")

  (define tmp (make-temporary-file "ws-~a.txt"))
  (display-to-file "hello\nworld\n" tmp #:exists 'replace)

  (define ed0 (editor-open "scratch" 20 5))
  (define ws0 (ws-empty))
  (check-false (ws-open? ws0 tmp))

  ;; 打开 → 建文档 + 记映射
  (define-values (ws1 ed1 did) (ws-open ws0 ed0 tmp))
  (check-true (ws-open? ws1 tmp))
  (check-equal? (ws-did ws1 tmp) did)
  (check-equal? (ws-path ws1 did) tmp)
  (check-equal? (document->string (document-entry-document (editor-document-entry ed1 did)))
                "hello\nworld\n")
  (check-equal? (editor-document-name ed1 did) (path->string (file-name-from-path tmp)))

  ;; 再开同一个 → 复用，不新建
  (define-values (ws2 ed2 did2) (ws-open ws1 ed1 tmp))
  (check-equal? did2 did)
  (check-true (eq? ed2 ed1))
  (check-equal? (length (editor-documents ed2)) 2)

  ;; 关 → 文档没了 + 映射清了
  (define-values (ws3 ed3) (ws-close ws2 ed2 did))
  (check-false (ws-open? ws3 tmp))
  (check-equal? (length (editor-documents ed3)) 1)

  (delete-file tmp)
  (displayln "lab/workspace.rkt: all tests passed"))

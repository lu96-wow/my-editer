#lang racket

;;; edit/document/document.rkt —— 文档 / 文件逻辑：打开 / 保存 + 脏
;;;
;;; 文件 I/O 与路径登记在这里（不在 session 内核）。
;;;   打开：去重 → 读盘 → add-document → 分屏放置 → 记 path → 规则层 → 记 saved 句柄
;;;   保存：写盘 → 记 saved 句柄
;;; 脏由 session-dirty? 从句柄身份派生；文件映射走 session-set-file（file-map）。
;;;
;;; 命令走 feature/handler 模式：本模块自带 cmd-* + handler，demo 里 document-install 挂上。

(require racket/file
         racket/path
         "../command/session.rkt"
         "../command/tables.rkt"
         "rules.rkt")

(provide session-open-file session-save session-save-all
         document-install
         (struct-out cmd-save) (struct-out cmd-open-file))

;;; ---------- 工具 ----------

(define (normalize p) (simplify-path (path->complete-path p)))
(define (basename p) (path->string (or (file-name-from-path (path->complete-path p)) p)))

;;; ---------- 打开 ----------

;; 打开文件到编辑区：已有同 path → 聚焦已有视图；否则新建文档 + 分屏显示。
;; axis：分屏方向（'lr | 'tb）。→ session
(define (session-open-file s path [rules default-rules] [axis 'lr])
  (define np (normalize path))
  (define existing (session-file-did s np))
  (cond
    [existing
     (define vs (session-view-ids-of s existing))
     (if (pair? vs) (session-show-view s (first vs)) s)]
    [else
     (define text (if (file-exists? np) (file->string np) ""))
     (define-values (s1 did nvid) (session-add-document s text 40 18 #:name (basename np)))
     (define base (session-edit-vid s1))
     (define s2 (if (and base (not (eqv? base nvid)))
                    (session-place-view s1 base axis nvid)
                    s1))
     (define s3 (session-set-file s2 did np))
     (define s4 (session-doc-set-keys s3 did edit-keys))   ; 默认命令表（先全部填默认）
     (define s5 (rules-apply rules s4 did np))             ; 规则层（暂空）可覆盖
     (define s6 (session-mark-saved s5 did))
     (session-show-view s6 nvid)]))

;;; ---------- 保存 ----------

;; 保存某文档（默认活动编辑视图的）。→ session
(define (session-save s [did #f])
  (define d (or did (let ([v (session-edit-vid s)]) (and v (session-view-did s v)))))
  (cond
    [(not d) s]
    [else
     (define path (session-file-path s d))
     (cond
       [(not path) s]                             ; 无路径：暂不实现另存为
       [else
        (call-with-output-file path #:exists 'replace
          (lambda (out) (display (session-document-string s d) out)))
        (session-mark-saved s d)])]))

;; 全部有路径的文档存盘（错误退出用）。
(define (session-save-all s)
  (for/fold ([s s]) ([d (in-list (session-file-dids s))])
    (session-save s d)))

;;; ---------- 命令 + handler ----------

(struct cmd-save () #:transparent)
(struct cmd-open-file () #:transparent)

(define (document-handler)
  (lambda (s cmd)
    (cond
      [(cmd-save? cmd) (session-save s)]
      [(cmd-open-file? cmd)
       (define iv (session-panel-vid s 'input))
       (if iv
           (session-prompt-open s iv "find file: "
                                (lambda (s path)
                                  (if (string=? path "") s (session-open-file s path))))
           s)]
      [else #f])))

;; 把文档命令挂到 session（handler 链）。
(define (document-install s)
  (session-add-handler s (document-handler)))

#lang racket

;;; edit/document/lifecycle.rkt —— 关闭 / 退出策略（交互）
;;;
;;; 有未保存修改时先问：关文档 / 关视图 / 退出。交互用 prompt 回调链实现，
;;; 不新增会话状态。依赖 document.rkt 的 session-save，不反向依赖 ——
;;; 所以 document-install 组装两部分 handler 放在这里。
;;;
;;;   document/document.rkt   打开 / 保存 / 新建 / 删除 + 保存/打开 handler
;;;   document/lifecycle.rkt  关闭 / 退出 + quit handler + document-install

(require racket/string
         "../session.rkt"
         "../command/command.rkt"
         "../core/keymap.rkt"
         "../core/ids.rkt"
         "document.rkt")

(provide session-close-doc session-close-view-checked session-quit-confirm
         lifecycle-handler document-install)

;;; ---------- 退出确认（有未保存修改时逐个询问） ----------

;; 解析答案 -> 'yes | 'no | 'all | 'nall | 'invalid
(define (quit-answer ans)
  (define a (string-downcase (string-trim ans)))
  (cond [(member a '("y" "yes")) 'yes]
        [(member a '("n" "no")) 'no]
        [(member a '("all" "a")) 'all]
        [(member a '("nall" "none" "!")) 'nall]
        [else 'invalid]))

;; 有路径且脏的文档（无路径不可能脏）。
(define (dirty-dids s)
  (for/list ([d (in-list (session-file-dids s))] #:when (session-dirty? s d)) d))

(define (session-quit-ask s remaining)
  (cond
    [(null? remaining) (session-quit s)]
    [else
     (define did (first remaining))
     (define more (rest remaining))
     (session-prompt-open s (session-panel-vid s panel-input)
       (format "save ~a? (y/n/all/nall) " (session-document-name s did))
       (lambda (s ans)
         (case (quit-answer ans)
           [(yes)  (session-quit-ask (session-save s did) more)]
           [(no)   (session-quit-ask s more)]
           [(all)  (session-quit
                    (for/fold ([s (session-save s did)]) ([d (in-list more)]) (session-save s d)))]
           [(nall) (session-quit s)]
           [else (session-quit-ask s remaining)])))]))   ; 无效输入：重问当前

;; 退出入口：没有脏文档直接退，否则逐个问。
(define (session-quit-confirm s)
  (define ds (dirty-dids s))
  (if (null? ds) (session-quit s) (session-quit-ask s ds)))

;;; ---------- 关闭（统一入口；脏则问） ----------

;; 'yes | 'no | 'invalid
(define (yes-no ans)
  (define a (string-downcase (string-trim ans)))
  (cond [(member a '("y" "yes")) 'yes]
        [(member a '("n" "no")) 'no]
        [else 'invalid]))

;; 关文档：脏则问是否保存。**唯一**的关文档入口。
(define (session-close-doc s did)
  (cond
    [(not (session-dirty? s did)) (session-close-document s did)]
    [else
     (session-prompt-open s (session-panel-vid s panel-input)
       (format "save ~a? (y/n) " (session-document-name s did))
       (lambda (s ans)
         (case (yes-no ans)
           [(yes) (session-close-document (session-save s did) did)]
           [(no)  (session-close-document s did)]
           [else  (session-close-doc s did)])))]))

;; 关视图：该文档最后一个视图 → 走关文档（会问）；否则直接关视图。
(define (session-close-view-checked s vid)
  (define did (session-view-did s vid))
  (if (null? (remove vid (session-document-view-list s did)))
      (session-close-doc s did)
      (session-close-view s vid)))

;;; ---------- handler + 装配 ----------

(define (lifecycle-handler)
  (lambda (s cmd)
    (cond [(cmd-quit? cmd) (session-quit-confirm s)]
          [else #f])))

;; 挂两个 handler：打开 / 保存（document）+ 退出（lifecycle）。
;; default-keys 作为打开文件的默认命令表。
(define (document-install s [default-keys (kbd)])
  (session-add-handler
   (session-add-handler s (document-handler default-keys))
   (lifecycle-handler)))

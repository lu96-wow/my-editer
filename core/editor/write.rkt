#lang racket

(require "state.rkt")

;;; editor/write.rkt —— 低层写口（能破坏结构一致）
;;;
;;; 这些原语只换结构的一部分：换整个 view 不校验 did、换 history 不换 view。
;;; 所以它们**不进 editor.rkt 标准入口**，
;;; 只有 command.rkt / sync.rkt / view.rkt（以及明确要摆弄低层的测试）直接 require。
;;;
;;; 公开面请用：编辑 / 导航 / 撤销命令、
;;; editor-view-set-sync / editor-view-set-link、editor-view-set-size。

(provide
 ;; ---------- 低层写口（可破坏结构一致） ----------
 editor-set-view
 editor-set-history)

;; 用 v 顶替同 id 的 view（v 的 did 合法性交给调用方）。
(define (editor-set-view ed v)
  (struct-copy editor ed
    [views (for/list ([x (in-list (editor-views ed))])
             (if (= (view-id x) (view-id v)) v x))]))

(define (editor-set-history ed did hist)
  (struct-copy editor ed
    [documents (for/list ([e (in-list (editor-documents ed))])
                 (if (= did (document-entry-id e)) (struct-copy document-entry e [history hist]) e))]))

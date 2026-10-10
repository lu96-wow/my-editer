#lang racket

;;; edit-rebuild/plugins/completion/worker.rkt —— place worker：算补全池的慢部分
;;;
;;; 主线程只发「要什么」，worker 回普通数据（字符串列表），可跨 place 序列化：
;;;   (module-paths)      → 已安装模块路径（lang/module-index）
;;;   (exports . mods)    → 各模块导出名（去重，module->exports）
;;;
;;; 慢的部分（目录扫描 / module->exports）都在这里，主线程只做本地解析与过滤。
;;; 文档查询是另一个 worker（doc-worker.rkt），补全不认识文档。

(require racket/match
         "../../core/async/runner.rkt"
         "../lang/module-index.rkt"
         "../lang/pool.rkt")

(provide main)

(define (main ch)
  (job-worker-main
   ch
   (lambda (req)
     (match req
       ['(module-paths) (force module-paths)]
       [(list 'exports mods)
        (distinct-strings (append* (for/list ([m (in-list mods)]) (module-exports m))))]
       [_ '()]))))

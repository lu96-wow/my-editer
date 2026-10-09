#lang racket

;;; edit/plugin/analysis/tools/worker.rkt —— 分析 worker（place 入口 + 沙箱 + 限额）
;;;
;;; 请求（跨 place 的普通 list）：
;;;   (list 'analyze path text version)  → analysis-result   （含展开，重；带时限）
;;;   (list 'lex     path text)          → lex-result        （只词法，快）
;;;
;;; 用 plugin/runner.rkt 的 job-worker-main：handler 抛异常 → job-result 失败，
;;; 主进程据此记日志，不会把半成品当成功。
;;;
;;; ⚠ expand 会执行被打开文件的编译期代码；call-with-limits 给时间上限（超时即失败）。
;;;   本模块不依赖 core / session / tui，可安全放进 place。

(require racket/match
         racket/sandbox
         "../../runner.rkt"
         "span.rkt"
         "analyze.rkt")

(provide worker-main)

(define (handle request)
  (match request
    [(list 'analyze path text version)
     (call-with-limits 30 #f (lambda () (analyze path text version)))]
    [(list 'lex path text)
     (call-with-limits 5 #f (lambda () (analyze-lex path text)))]
    [_ (error 'analysis-worker "未知请求: ~a" request)]))

(define (worker-main ch) (job-worker-main ch handle))

#lang racket

;;; edit/plugin/analysis/tools/span.rkt —— 分析工具的坐标 / 数据形状（纯）
;;;
;;; 工具层内部统一用 **0-based 字符偏移**（半开区间 [start,end)）：
;;;   · drracket/check-syntax 的 syntax-position 是 1-based，减一；
;;;   · syntax-color lexer 也报 1-based，减一。
;;; 跨行 token（字符串 / 块注释 / 多行字符串）用偏移天然能表达，不必先切行。
;;;
;;; 全部 #:prefab：可安全跨 place 序列化（工具要能丢进 worker）。
;;; 编辑器坐标 (line,col) 的换算在 pos.rkt；本模块不依赖 core / session / tui。

(provide (struct-out span) (struct-out token) (struct-out sem-token)
         (struct-out occurrence) (struct-out definition) (struct-out diagnostic)
         (struct-out lex-result) (struct-out expand-result) (struct-out analysis-result)
         span-empty? span-length span-contains? span-intersect? span-normalize)

;;; ---------- 位置 ----------

(struct span (start end) #:prefab)
;; start / end : 0-based 字符偏移，半开 [start,end)

(define (span-normalize s)
  (define a (span-start s))
  (define b (span-end s))
  (if (<= a b) s (span b a)))

(define (span-empty? s) (= (span-start s) (span-end s)))
(define (span-length s) (max 0 (- (span-end s) (span-start s))))

(define (span-contains? s pos)
  (and (<= (span-start s) pos) (< pos (span-end s))))

(define (span-intersect? a b)
  (and (< (span-start a) (span-end b)) (< (span-start b) (span-end a))))

;;; ---------- token ----------

(struct token (span type) #:prefab)
;; 词法 token（forest / 缩进 / 结构查询用）。type 见 lexer.rkt 的归一化集合。

(struct sem-token (span type modifiers) #:prefab)
;; 语义 token（展开后）。type ∈ function|variable|string|number|regexp|comment；
;; modifiers : (listof symbol)（definition / readonly / static / deprecated …）。

;;; ---------- 定义 / 引用 / 诊断 ----------

(struct occurrence (span name target) #:prefab)         ; 一个标识符出现；target = 定义所在文件 | #f
(struct definition (span name path) #:prefab)          ; 定义（path = 定义所在文件）
(struct diagnostic (span severity message) #:prefab)   ; severity ∈ error|warning|info

;;; ---------- 结果 ----------

(struct lex-result (path tokens) #:prefab)
;; 便宜、可先出：词法 token（forest / 结构查询 / 缩进）。

(struct expand-result (path sem-tokens definitions uses diagnostics) #:prefab)
;; 贵、异步后到：展开后的语义信息。

(struct analysis-result (path version lex expand) #:prefab)
;; lex    : lex-result
;; expand : expand-result | #f（未完成 / 失败）

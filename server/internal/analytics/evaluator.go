package analytics

import (
	"fmt"
	"math"
	"strconv"
	"strings"
)

// Évaluateur arithmétique des mesures combinées. L'expression ne touche
// jamais SQL : elle est évaluée en Go sur les nombres déjà agrégés. Grammaire :
//   expr   := term (('+'|'-') term)*
//   term   := unary (('*'|'/') unary)*
//   unary  := '-' unary | primary
//   primary:= number | ident ('.' ident)? | '(' expr ')' | func '(' expr (',' expr)* ')'
// Fonctions : nullif(a,b), coalesce(a,b), abs(a), round(a), min(a,b), max(a,b).

type exprNode interface {
	eval(vars map[string]*float64) (*float64, error)
}

type numNode struct{ v float64 }
type varNode struct{ name string }
type binNode struct {
	op   byte
	l, r exprNode
}
type negNode struct{ x exprNode }
type funcNode struct {
	name string
	args []exprNode
}

func (n numNode) eval(map[string]*float64) (*float64, error) { v := n.v; return &v, nil }
func (n varNode) eval(vars map[string]*float64) (*float64, error) {
	v, ok := vars[n.name]
	if !ok {
		return nil, fmt.Errorf("mesure inconnue dans l'expression : %s", n.name)
	}
	return v, nil
}
func (n negNode) eval(vars map[string]*float64) (*float64, error) {
	v, err := n.x.eval(vars)
	if err != nil || v == nil {
		return nil, err
	}
	r := -*v
	return &r, nil
}
func (n binNode) eval(vars map[string]*float64) (*float64, error) {
	l, err := n.l.eval(vars)
	if err != nil {
		return nil, err
	}
	r, err := n.r.eval(vars)
	if err != nil {
		return nil, err
	}
	if l == nil || r == nil {
		return nil, nil
	}
	var v float64
	switch n.op {
	case '+':
		v = *l + *r
	case '-':
		v = *l - *r
	case '*':
		v = *l * *r
	case '/':
		if *r == 0 {
			return nil, nil
		}
		v = *l / *r
	}
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return nil, nil
	}
	return &v, nil
}
func (n funcNode) eval(vars map[string]*float64) (*float64, error) {
	vals := make([]*float64, len(n.args))
	for i, a := range n.args {
		v, err := a.eval(vars)
		if err != nil {
			return nil, err
		}
		vals[i] = v
	}
	f := func(x float64) *float64 { return &x }
	switch n.name {
	case "nullif":
		if vals[0] == nil || vals[1] == nil {
			return vals[0], nil
		}
		if *vals[0] == *vals[1] {
			return nil, nil
		}
		return vals[0], nil
	case "coalesce":
		for _, v := range vals {
			if v != nil {
				return v, nil
			}
		}
		return nil, nil
	case "abs":
		if vals[0] == nil {
			return nil, nil
		}
		return f(math.Abs(*vals[0])), nil
	case "round":
		if vals[0] == nil {
			return nil, nil
		}
		return f(math.Round(*vals[0])), nil
	case "min", "max":
		var best *float64
		for _, v := range vals {
			if v == nil {
				continue
			}
			if best == nil || (n.name == "min" && *v < *best) || (n.name == "max" && *v > *best) {
				x := *v
				best = &x
			}
		}
		return best, nil
	}
	return nil, fmt.Errorf("fonction inconnue : %s", n.name)
}

var funcArity = map[string]int{"nullif": 2, "coalesce": -1, "abs": 1, "round": 1, "min": -1, "max": -1}

type exprParser struct {
	s   string
	pos int
	// identifiants rencontrés (pour validation contre les alias connus)
	idents []string
}

func parseExpr(s string) (exprNode, []string, error) {
	p := &exprParser{s: s}
	n, err := p.parseSum()
	if err != nil {
		return nil, nil, err
	}
	p.skip()
	if p.pos != len(p.s) {
		return nil, nil, fmt.Errorf("expression invalide près de « %s »", p.s[p.pos:])
	}
	return n, p.idents, nil
}

func (p *exprParser) skip() {
	for p.pos < len(p.s) && (p.s[p.pos] == ' ' || p.s[p.pos] == '\t') {
		p.pos++
	}
}
func (p *exprParser) peek() byte {
	p.skip()
	if p.pos >= len(p.s) {
		return 0
	}
	return p.s[p.pos]
}
func (p *exprParser) parseSum() (exprNode, error) {
	l, err := p.parseTerm()
	if err != nil {
		return nil, err
	}
	for {
		c := p.peek()
		if c != '+' && c != '-' {
			return l, nil
		}
		p.pos++
		r, err := p.parseTerm()
		if err != nil {
			return nil, err
		}
		l = binNode{op: c, l: l, r: r}
	}
}
func (p *exprParser) parseTerm() (exprNode, error) {
	l, err := p.parseUnary()
	if err != nil {
		return nil, err
	}
	for {
		c := p.peek()
		if c != '*' && c != '/' {
			return l, nil
		}
		p.pos++
		r, err := p.parseUnary()
		if err != nil {
			return nil, err
		}
		l = binNode{op: c, l: l, r: r}
	}
}
func (p *exprParser) parseUnary() (exprNode, error) {
	if p.peek() == '-' {
		p.pos++
		x, err := p.parseUnary()
		if err != nil {
			return nil, err
		}
		return negNode{x}, nil
	}
	return p.parsePrimary()
}
func isIdentStart(c byte) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}
func isIdentChar(c byte) bool { return isIdentStart(c) || (c >= '0' && c <= '9') }

func (p *exprParser) parsePrimary() (exprNode, error) {
	c := p.peek()
	switch {
	case c == '(':
		p.pos++
		n, err := p.parseSum()
		if err != nil {
			return nil, err
		}
		if p.peek() != ')' {
			return nil, fmt.Errorf("parenthèse fermante manquante")
		}
		p.pos++
		return n, nil
	case c >= '0' && c <= '9' || c == '.':
		start := p.pos
		for p.pos < len(p.s) && (p.s[p.pos] >= '0' && p.s[p.pos] <= '9' || p.s[p.pos] == '.') {
			p.pos++
		}
		v, err := strconv.ParseFloat(p.s[start:p.pos], 64)
		if err != nil {
			return nil, fmt.Errorf("nombre invalide")
		}
		return numNode{v}, nil
	case isIdentStart(c):
		start := p.pos
		for p.pos < len(p.s) && (isIdentChar(p.s[p.pos]) || p.s[p.pos] == '.') {
			p.pos++
		}
		name := p.s[start:p.pos]
		if p.peek() == '(' {
			fn := strings.ToLower(name)
			ar, ok := funcArity[fn]
			if !ok {
				return nil, fmt.Errorf("fonction inconnue : %s", name)
			}
			p.pos++
			var args []exprNode
			for {
				a, err := p.parseSum()
				if err != nil {
					return nil, err
				}
				args = append(args, a)
				if p.peek() == ',' {
					p.pos++
					continue
				}
				break
			}
			if p.peek() != ')' {
				return nil, fmt.Errorf("parenthèse fermante manquante")
			}
			p.pos++
			if ar >= 0 && len(args) != ar {
				return nil, fmt.Errorf("%s attend %d argument(s)", fn, ar)
			}
			if ar < 0 && len(args) < 1 {
				return nil, fmt.Errorf("%s attend au moins un argument", fn)
			}
			return funcNode{name: fn, args: args}, nil
		}
		p.idents = append(p.idents, name)
		return varNode{name}, nil
	}
	if c == 0 {
		return nil, fmt.Errorf("expression incomplète")
	}
	return nil, fmt.Errorf("caractère inattendu « %c »", c)
}

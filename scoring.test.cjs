const assert=require('node:assert/strict');const {seriesState,leaderboard}=require(require('node:fs').existsSync('./dist/scoring.js')?'./dist/scoring.js':'./scoring.js');
const games=Array.from({length:7},(_,i)=>({id:i+1,game_no:i+1,score_a:i<4?5:null,score_b:i<4?3:null}));
assert.deepEqual(seriesState(games),{a:4,b:0,clinch:4,champion:'a'});
const p=(u,g,w,a,b)=>({user_id:u,game_id:g,winner:w,score_a:a,score_b:b});let picks=[];for(let i=1;i<=4;i++){picks.push(p('A',i,'a',4,2),p('B',i,'a',5,3),p('C',i,'b',3,5),p('D',i,'a',5,3));}picks.push(p('A',7,'b',0,9));
let rows=leaderboard(games,picks,[]);assert.deepEqual(rows.map(r=>[r.id,r.correct,r.error,r.rank]),[['B',4,0,1],['D',4,0,1],['A',4,8,3],['C',0,16,4]]);
const mixed=games.map((g,i)=>({...g,score_a:i<2?5:null,score_b:i<2?3:null}));rows=leaderboard(mixed,[p('A',1,'a',5,3),p('B',1,'a',7,1),p('B',2,'b',3,5)],[]);assert.equal(rows[0].id,'B');assert.equal(rows[1].error,null);
assert.equal(seriesState([{game_no:1,score_a:0,score_b:2}]).b,1);
assert.equal(leaderboard([],[],[]).length,0);console.log('Passed: sweep clinch, excluded unused game, correct-winner priority, score error, shared ranks, missing picks, zero scores.');
